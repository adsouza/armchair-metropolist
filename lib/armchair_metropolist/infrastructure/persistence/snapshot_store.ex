defmodule ArmchairMetropolist.Infrastructure.Persistence.SnapshotStore do
  @moduledoc "Ecto/Postgres adapter implementing the SnapshotRepository port."

  @behaviour ArmchairMetropolist.Domain.Ports.SnapshotRepository

  import Ecto.Query

  alias ArmchairMetropolist.Infrastructure.Persistence.{CitySnapshot, Repo}

  # Same cold-VM hazard as the file adapter: `:safe` will not create atoms, and a
  # stored city is full of them. See FileSnapshotStore.ensure_vocabulary_loaded/0
  # for the full explanation — the failure is silent and only appears on boots
  # where nothing else has loaded the domain entities first.
  @vocabulary [
    ArmchairMetropolist.Domain.Entities.CityMap,
    ArmchairMetropolist.Domain.Entities.Node
  ]

  @impl true
  def load_latest do
    Enum.each(@vocabulary, &Code.ensure_loaded!/1)

    query = from(s in CitySnapshot, order_by: [desc: s.tick], limit: 1)

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
  end

  defp decode(tick, payload, checksum) do
    if :crypto.hash(:md5, payload) |> Base.encode16() == checksum do
      {:ok, {tick, :erlang.binary_to_term(payload, [:safe])}}
    else
      {:error, :checksum_mismatch}
    end
  end
end
