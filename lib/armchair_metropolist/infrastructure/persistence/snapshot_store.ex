defmodule ArmchairMetropolist.Infrastructure.Persistence.SnapshotStore do
  @moduledoc """
  Ecto/Postgres adapter implementing the SnapshotRepository port.

  One row per city, keyed by `city_id`, upserted on every save.

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
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    # An explicit `set:` rather than `on_conflict: :replace_all`, for two reasons:
    # :replace_all would also overwrite inserted_at, losing when the city was first
    # created; and updated_at must move on every save because the reaper sweeps on it.
    %CitySnapshot{}
    |> CitySnapshot.changeset(%{
      city_id: city_id,
      tick: tick,
      payload: payload,
      checksum: checksum
    })
    |> Repo.insert(
      on_conflict: [set: [tick: tick, payload: payload, checksum: checksum, updated_at: now]],
      conflict_target: :city_id
    )
    |> case do
      {:ok, _snapshot} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  rescue
    # Postgrex.Error, DBConnection.ConnectionError, and anything else the driver
    # throws on the way to the socket.
    exception -> {:error, exception}
  catch
    # An exhausted or un-owned pool exits rather than raising.
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
      {:ok, {tick, :erlang.binary_to_term(payload, [:safe])}}
    else
      {:error, :checksum_mismatch}
    end
  end
end
