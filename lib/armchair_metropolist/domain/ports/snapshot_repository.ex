defmodule ArmchairMetropolist.Domain.Ports.SnapshotRepository do
  @moduledoc """
  Output port for snapshot persistence.

  Speaks `CityMap` only. Serialisation and checksumming are adapter concerns —
  if `binary` or `checksum` appeared here, the domain would have learned about
  storage encoding.
  """

  alias ArmchairMetropolist.Domain.Entities.CityMap

  @doc """
  Load the city stored under `city_id`.

  One row per city, so there is no ordering to apply and nothing to be *latest*
  among — the name says `load` rather than `load_latest` for that reason.
  """
  @callback load(String.t()) ::
              {:ok, {non_neg_integer(), CityMap.t()}} | {:error, term()}

  @doc """
  Persist `city_map` under `city_id`. Overwrites whatever was there.

  `tick` is passed separately because it is the adapter's business what to do
  with it — the Postgres adapter stores it as a column, and the file adapter puts
  it in its envelope. `city_map` carries the authoritative tick regardless.
  """
  @callback save(String.t(), non_neg_integer(), CityMap.t()) :: :ok | {:error, term()}
end
