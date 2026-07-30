defmodule ArmchairMetropolist.Domain.Ports.SnapshotRepository do
  @moduledoc """
  Output port for snapshot persistence.

  Speaks `CityMap` only. Serialisation and checksumming are adapter concerns —
  if `binary` or `checksum` appeared here, the domain would have learned about
  storage encoding.
  """

  alias ArmchairMetropolist.Domain.Entities.CityMap

  @callback load_latest() ::
              {:ok, {non_neg_integer(), CityMap.t()}} | {:error, :not_found | term()}
  @callback save(non_neg_integer(), CityMap.t()) :: :ok | {:error, term()}
end
