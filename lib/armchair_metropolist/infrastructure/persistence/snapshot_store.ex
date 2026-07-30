defmodule ArmchairMetropolist.Infrastructure.Persistence.SnapshotStore do
  @moduledoc """
  Ecto/Postgres adapter implementing the SnapshotRepository port.

  Snapshots are append-only; `load_latest/0` orders by `desc: tick`, so **the
  highest tick wins** rather than the most recent insert. `FileSnapshotStore`
  documents the same rule, which is what makes the two interchangeable.

  ## Failures are returned, never raised

  `save/2` catches the database talking back. `Repo.insert/1` already answers
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
  def load_latest do
    # Mandatory before decode/3's `:safe` call — see SnapshotVocabulary. This adapter
    # has no rescue, so without it the ArgumentError escapes CityEngine's hydration
    # and the engine crash-loops.
    SnapshotVocabulary.ensure_loaded!()

    # `desc: s.id` breaks ties deterministically. An engine that crashes and
    # replays can write two rows at the same tick with different content, and
    # `desc: s.tick` alone leaves which one wins unspecified.
    query = from(s in CitySnapshot, order_by: [desc: s.tick, desc: s.id], limit: 1)

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      %CitySnapshot{tick: tick, payload: payload, checksum: checksum} ->
        decode(tick, payload, checksum)
    end
  end

  @impl true
  def save(tick, city_map) do
    payload = :erlang.term_to_binary(city_map, [:compressed])
    checksum = :crypto.hash(:md5, payload) |> Base.encode16()

    %CitySnapshot{}
    |> CitySnapshot.changeset(%{tick: tick, payload: payload, checksum: checksum})
    |> Repo.insert()
    |> case do
      {:ok, _snapshot} -> :ok
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

  defp decode(tick, payload, checksum) do
    if :crypto.hash(:md5, payload) |> Base.encode16() == checksum do
      {:ok, {tick, :erlang.binary_to_term(payload, [:safe])}}
    else
      {:error, :checksum_mismatch}
    end
  end
end
