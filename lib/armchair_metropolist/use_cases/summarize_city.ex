defmodule ArmchairMetropolist.UseCases.SummarizeCity do
  @moduledoc """
  Reports the current metrics for a city without advancing it.

  ## Why this exists

  The boundary graph deliberately bars `Infrastructure` from `Domain.Services` —
  that is what stops the web and infrastructure layers reaching into simulation
  logic. `CityEngine` therefore *cannot* call
  `SimulationCalculator.metrics/1` itself; the compiler rejects it. `UseCases` is
  the one layer permitted to reach `Domain.Services`, so the read-only path has to
  live here.

  Before this existed, the engine fell back to `SimulationMetrics.build(city_map,
  %{})` when hydrating, which produced a well-formed struct with an **empty**
  `resources` map. A LiveView mounting before the first tick therefore had no
  supply/demand figures to show, and after a place or demolish the counters
  lagged by up to one tick.

  Read-only by construction: the returned `tick` is whatever the given map already
  carried. Advancing is `AdvanceCityTick`'s job and nothing else's.
  """

  alias ArmchairMetropolist.Domain.Entities.{CityMap, SimulationMetrics}
  alias ArmchairMetropolist.Domain.Services.SimulationCalculator

  @doc """
  Computes metrics for `city_map`, including per-resource supply/demand.

  Always succeeds — it is pure aggregation over a value already in hand — but
  returns a tagged tuple to match the other use cases, so callers do not have to
  remember which ones can fail.
  """
  @spec execute(CityMap.t()) :: {:ok, SimulationMetrics.t()}
  def execute(%CityMap{} = city_map) do
    {:ok, SimulationCalculator.metrics(city_map)}
  end
end
