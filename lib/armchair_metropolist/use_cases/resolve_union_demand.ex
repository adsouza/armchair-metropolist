defmodule ArmchairMetropolist.UseCases.ResolveUnionDemand do
  @moduledoc "Resolve a pending union wage demand or settle an active strike."

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Services.SimulationCalculator

  @type response :: :accept | :reject
  @type error :: :no_demand | :already_resolved | :invalid_response

  @spec execute(CityMap.t(), response()) :: {:ok, CityMap.t()} | {:error, error()}
  def execute(%CityMap{} = city_map, response) when response in [:accept, :reject] do
    case SimulationCalculator.union_demand(city_map) do
      nil ->
        {:error, :no_demand}

      %{pending: false} when response == :reject ->
        {:error, :already_resolved}

      demand ->
        {:ok, settle(city_map, demand.level, response)}
    end
  end

  def execute(%CityMap{}, _response), do: {:error, :invalid_response}

  defp settle(city_map, level, :accept) do
    city_map
    |> Map.put(:union_wage_level, level)
    |> Map.put(:union_strike_level, 0)
    |> CityMap.increment_revision()
  end

  defp settle(city_map, level, :reject) do
    city_map
    |> Map.put(:union_strike_level, level)
    |> CityMap.increment_revision()
  end
end
