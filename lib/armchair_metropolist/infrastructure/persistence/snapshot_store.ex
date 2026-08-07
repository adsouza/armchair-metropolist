defmodule ArmchairMetropolist.Infrastructure.Persistence.SnapshotStore do
  @moduledoc """
  Ecto/Postgres adapter implementing the SnapshotRepository port.

  One row per city, keyed by `city_id`.

  ## A save cannot move a city backwards

  `save/3` refuses and returns `{:stale, stored_tick}` when the stored row is already
  at `tick` or later, rather than overwriting it. See the port's moduledoc for why:
  a crashed-and-replayed engine can otherwise write an older city over a newer one.
  The read, the comparison and the write happen inside one `FOR UPDATE`-locked
  transaction so nothing else can slip a save in between the check and the write.

  ## Failures are returned, never raised

  `save/3` catches the database talking back. `Repo.insert/1` already answers
  `{:error, changeset}` for a rejected changeset, but a dead connection, a
  checkout timeout or a missing table *raise* (`DBConnection.ConnectionError`,
  `Postgrex.Error`) and an exhausted pool `exit`s. Left alone, any of those blew
  up `CityEngine.handle_info/2` mid-checkpoint, restarting the engine and rolling
  its state back to the previous checkpoint — fifty ticks of the player's work
  traded for one lost snapshot. The port declares `{:error, term()}` for exactly
  this, and `CityEngine` logs it and carries on.
  """

  @behaviour ArmchairMetropolist.Domain.Ports.SnapshotRepository

  import Ecto.Query

  alias ArmchairMetropolist.Infrastructure.Persistence.{CitySnapshot, Repo, SnapshotVocabulary}

  @impl true
  def load(city_id) do
    # Mandatory before decode/3's `:safe` call — see SnapshotVocabulary. This adapter
    # has no rescue, so without it the ArgumentError escapes CityEngine's hydration
    # and the engine crash-loops.
    SnapshotVocabulary.ensure_loaded!()

    case Repo.get(CitySnapshot, city_id) do
      nil ->
        {:error, :not_found}

      %CitySnapshot{tick: tick, payload: payload, checksum: checksum} ->
        decode(tick, payload, checksum)
    end
  end

  @impl true
  def save(city_id, tick, city_map) do
    payload = :erlang.term_to_binary(city_map, [:compressed])
    checksum = :crypto.hash(:md5, payload) |> Base.encode16()

    # Read-then-write in a transaction, rather than a query-based `on_conflict` with a
    # `where: s.tick < ^tick`. The SQL form is terser and refuses the stale write just
    # as well, but it gives no way to tell a refused update from an applied one — and
    # the port requires the refusal be *reportable*, not merely effective.
    #
    # `FOR UPDATE` is belt-and-braces: the Registry guarantees one engine per city, so
    # nothing else writes this row. It costs one lock on a once-per-checkpoint write and
    # removes the need to reason about that guarantee holding forever.
    Repo.transaction(fn ->
      existing =
        Repo.one(from(s in CitySnapshot, where: s.city_id == ^city_id, lock: "FOR UPDATE"))

      case existing do
        %CitySnapshot{tick: stored} when stored >= tick ->
          {:stale, stored}

        _ ->
          changeset =
            CitySnapshot.changeset(existing || %CitySnapshot{}, %{
              city_id: city_id,
              tick: tick,
              payload: payload,
              checksum: checksum
            })

          # Ecto's timestamps() move updated_at on the update path, which is what the
          # reaper sweeps on. inserted_at is left alone, so a city keeps its creation
          # time across every later save.
          result = if existing, do: Repo.update(changeset), else: Repo.insert(changeset)

          case result do
            {:ok, _snapshot} -> :ok
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
    |> case do
      {:ok, outcome} -> outcome
      {:error, reason} -> {:error, reason}
    end
  rescue
    # Postgrex.Error, DBConnection.ConnectionError, and anything else the driver
    # throws on the way to the socket.
    exception -> {:error, exception}
  catch
    # An exhausted or un-owned pool exits rather than raising.
    kind, value -> {:error, {kind, value}}
  end

  @impl true
  def delete(city_id) do
    Repo.delete_all(from(s in CitySnapshot, where: s.city_id == ^city_id))

    :ok
  rescue
    # Same never-raise policy as `save/3` above, and for the same reason: this runs
    # inside a `GenServer.call` on the engine, and a raise there takes the city with it.
    exception -> {:error, exception}
  catch
    kind, value -> {:error, {kind, value}}
  end

  # sobelow_skip ["Misc.BinToTerm"]
  # `:safe` stops atom, pid and function creation but not a deliberately huge or
  # deeply nested term, which is why Sobelow flags this regardless. Accepted because
  # the payload is a row this application wrote to its own `city_snapshots` table,
  # not anything a user submits; reaching it requires database write access. The
  # checksum beside it detects corruption, not tampering.
  defp decode(tick, payload, checksum) do
    if :crypto.hash(:md5, payload) |> Base.encode16() == checksum do
      # modernize/1 rewrites node types retired by a rename, so a row written
      # under the old vocabulary hydrates instead of crash-looping the engine.
      city_map =
        payload
        |> :erlang.binary_to_term([:safe])
        |> SnapshotVocabulary.modernize()

      {:ok, {tick, city_map}}
    else
      {:error, :checksum_mismatch}
    end
  end
end
