defmodule ArmchairMetropolist.UseCases.IssueCommercialBond do
  @moduledoc "Use case: issue the one-time bridge that keeps a commercial rescue affordable."

  alias ArmchairMetropolist.Domain.Entities.{CityMap, MunicipalBond}
  alias ArmchairMetropolist.Domain.Services.SimulationCalculator

  @type error :: :already_issued | :not_eligible

  @spec execute(CityMap.t()) :: {:ok, CityMap.t()} | {:error, error()}
  def execute(%CityMap{commercial_bond: bond}) when not is_nil(bond),
    do: {:error, :already_issued}

  def execute(%CityMap{} = city_map) do
    case SimulationCalculator.metrics(city_map).commercial_bond_offer do
      %{principal: principal} ->
        next =
          city_map
          |> Map.put(:commercial_bond, MunicipalBond.commercial_bridge(principal, city_map.tick))
          |> Map.update!(:money, &(&1 + principal))
          |> CityMap.increment_revision()

        {:ok, next}

      nil ->
        {:error, :not_eligible}
    end
  end
end
