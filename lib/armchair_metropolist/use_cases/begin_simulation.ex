defmodule ArmchairMetropolist.UseCases.BeginSimulation do
  @moduledoc "Start the city clock after the player finishes opening planning."

  alias ArmchairMetropolist.Domain.Entities.{CityMap, MunicipalBond}

  @type error :: :bond_not_issued | :already_started | :empty_city

  @spec execute(CityMap.t()) :: {:ok, CityMap.t()} | {:error, error()}
  def execute(%CityMap{municipal_bond: nil}), do: {:error, :bond_not_issued}

  def execute(%CityMap{municipal_bond: bond} = city_map) do
    cond do
      not MunicipalBond.issued?(bond) ->
        {:error, :bond_not_issued}

      not MunicipalBond.planning?(bond) ->
        {:error, :already_started}

      map_size(city_map.nodes) == 0 ->
        {:error, :empty_city}

      true ->
        city_map = %{
          city_map
          | municipal_bond: MunicipalBond.start(bond, city_map.tick)
        }

        {:ok, CityMap.increment_revision(city_map)}
    end
  end
end
