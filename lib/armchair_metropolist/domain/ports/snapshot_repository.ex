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
  Persist `city_map` under `city_id`.

  Returns `{:stale, stored_tick}` and writes nothing when a snapshot at `tick` or
  later is already stored. **That is not an error.** It is the guarantee that a
  crashed engine which hydrated from an older snapshot cannot overwrite newer work
  with older — the case `docs/superpowers/2026-07-30-follow-ups.md` records, and the
  one the previous append-only layout protected against by ordering on tick rather
  than on write time. Adapters must honour it; callers rely on a save never moving a
  city backwards.

  `tick` is passed separately because it is the adapter's business what to do with
  it — the Postgres adapter stores it as a column, and the file adapter puts it in
  its envelope. `city_map` carries the authoritative tick regardless.
  """
  @callback save(String.t(), non_neg_integer(), CityMap.t()) ::
              :ok | {:stale, non_neg_integer()} | {:error, term()}

  @doc """
  Delete the city stored under `city_id`.

  Returns `:ok` when nothing was stored — a reset of a city that has never been
  checkpointed is ordinary, not a failure.

  Exists because `save/3` is monotonic in tick and must stay that way. A reset city
  starts again at tick 0, which `save/3` correctly refuses as stale until the new city
  outlives the old one; deleting the stored row is how a wipe becomes durable without
  putting a hole in that guarantee. See `UseCases.ResetCity` and
  `Infrastructure.Simulation.CityEngine.handle_call(:reset, …)`.
  """
  @callback delete(String.t()) :: :ok | {:error, term()}
end
