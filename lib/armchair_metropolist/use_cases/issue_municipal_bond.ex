defmodule ArmchairMetropolist.UseCases.IssueMunicipalBond do
  @moduledoc "Use case: authorize the one municipal bond issue that funds a new city."

  alias ArmchairMetropolist.Domain.Entities.{CityMap, MunicipalBond}

  @type error :: :invalid_issue | :not_pristine | :already_financed

  @spec execute(CityMap.t(), float()) :: {:ok, CityMap.t()} | {:error, error()}
  def execute(%CityMap{municipal_bond: bond}, _principal) when not is_nil(bond),
    do: {:error, :already_financed}

  def execute(%CityMap{} = city_map, principal) do
    with {:ok, bond} <- MunicipalBond.new(principal),
         true <- pristine?(city_map) do
      next =
        city_map
        |> Map.put(:municipal_bond, bond)
        |> Map.put(:money, principal)
        |> CityMap.increment_revision()

      {:ok, next}
    else
      {:error, :invalid_issue} -> {:error, :invalid_issue}
      false -> {:error, :not_pristine}
    end
  end

  defp pristine?(city_map) do
    city_map.tick == 0 and city_map.revision == 0 and map_size(city_map.nodes) == 0 and
      city_map.money == 0.0 and city_map.waste_stock == 0.0
  end
end
