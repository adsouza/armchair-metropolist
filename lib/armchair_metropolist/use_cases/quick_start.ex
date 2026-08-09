defmodule ArmchairMetropolist.UseCases.QuickStart do
  @moduledoc "Place a balanced five-block starter plan in one command."

  alias ArmchairMetropolist.Domain.Entities.{CityMap, MunicipalBond, Node}
  alias ArmchairMetropolist.UseCases.ManageInfrastructure

  @types [:power_plant, :commercial, :water_plant, :residential, :park]

  @doc "The block types added by a quick start, in placement order."
  def types, do: @types

  @doc "The treasury required to add the complete starter plan."
  def cost do
    Enum.sum(Enum.map(@types, &Node.construction_cost/1))
  end

  @doc "Add one of every starter type to available cells during opening planning."
  @spec execute(CityMap.t()) ::
          {:ok, %{city_map: CityMap.t(), nodes: [Node.t()]}}
          | {:error,
             :financing_required
             | :already_started
             | :bond_default
             | :insufficient_funds
             | :grid_full}
  def execute(%CityMap{} = city_map) do
    cond do
      is_nil(city_map.municipal_bond) ->
        {:error, :financing_required}

      not MunicipalBond.planning?(city_map.municipal_bond) ->
        {:error, :already_started}

      city_map.money < cost() ->
        {:error, :insufficient_funds}

      true ->
        place_types(city_map)
    end
  end

  defp place_types(city_map) do
    result =
      Enum.reduce_while(@types, {:ok, {city_map, []}}, fn type, {:ok, {map, nodes}} ->
        case next_available_cell(map) do
          {map, {x, y}} ->
            case ManageInfrastructure.place(map, x, y, type) do
              {:ok, {next_map, node}} ->
                {:cont, {:ok, {next_map, [node | nodes]}}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end

          :grid_full ->
            {:halt, {:error, :grid_full}}
        end
      end)

    case result do
      {:ok, {map, nodes}} -> {:ok, %{city_map: map, nodes: Enum.reverse(nodes)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp next_available_cell(city_map) do
    case find_available_cell(city_map) do
      nil ->
        grown = CityMap.grow_if_crowded(city_map)

        if grown == city_map do
          :grid_full
        else
          {grown, find_available_cell(grown)}
        end

      coordinates ->
        {city_map, coordinates}
    end
  end

  defp find_available_cell(city_map) do
    cells =
      for y <- city_map.min_y..(city_map.min_y + city_map.height - 1),
          x <- city_map.min_x..(city_map.min_x + city_map.width - 1),
          not CityMap.occupied?(city_map, x, y),
          do: {x, y}

    List.first(cells)
  end
end
