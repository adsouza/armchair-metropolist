defmodule ArmchairMetropolist.UseCases.ResetCity do
  @moduledoc "Use case: discard a city and start a new one on the same grid."

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Entities.SimulationMetrics
  alias ArmchairMetropolist.Domain.Services.SimulationCalculator

  @doc """
  Reset `city_map` and return it with its metrics.

  Metrics describe the *new* map, mirroring `AdvanceCityTick.execute/1`, which computes
  from the post-tick map for the same reason.

  This use case exists so `Infrastructure.Simulation.CityEngine` can get those metrics at
  all: the boundary graph bars `Infrastructure` from `Domain.Services`, so the engine
  cannot call `SimulationCalculator` itself.

  Persisting the reset is deliberately *not* here. It needs the city id and the
  repository, neither of which belongs in a pure function; see the engine's
  `handle_call(:reset, …)`.
  """
  @spec execute(CityMap.t()) :: {:ok, %{city_map: CityMap.t(), metrics: SimulationMetrics.t()}}
  def execute(city_map) do
    next = CityMap.reset(city_map)

    {:ok, %{city_map: next, metrics: SimulationCalculator.metrics(next)}}
  end
end
