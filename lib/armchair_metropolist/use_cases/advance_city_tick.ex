defmodule ArmchairMetropolist.UseCases.AdvanceCityTick do
  @moduledoc "Use case: advance the city simulation by one tick."

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Services.SimulationCalculator

  @doc """
  Advance the given city map by one tick.

  Returns `{:ok, %{city_map: CityMap.t(), delta: map(), metrics: SimulationMetrics.t()}}`.

  Metrics describe the *post-tick* map, so they are computed from the map
  `SimulationCalculator.advance_tick/1` returns rather than the one passed in.
  """
  @spec execute(CityMap.t()) ::
          {:ok,
           %{
             city_map: CityMap.t(),
             delta: SimulationCalculator.delta(),
             metrics: ArmchairMetropolist.Domain.Entities.SimulationMetrics.t()
           }}
  def execute(city_map) do
    {next_city_map, delta} = SimulationCalculator.advance_tick(city_map)
    metrics = SimulationCalculator.metrics(next_city_map)

    {:ok, %{city_map: next_city_map, delta: delta, metrics: metrics}}
  end
end
