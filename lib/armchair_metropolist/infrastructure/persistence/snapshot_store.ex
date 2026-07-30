defmodule ArmchairMetropolist.Infrastructure.Persistence.SnapshotStore do
  @moduledoc "Ecto/Postgres adapter implementing the SnapshotRepository port."

  @behaviour ArmchairMetropolist.Domain.Ports.SnapshotRepository

  import Ecto.Query

  alias ArmchairMetropolist.Infrastructure.Persistence.{CitySnapshot, Repo}

  @impl true
  def load_latest do
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
