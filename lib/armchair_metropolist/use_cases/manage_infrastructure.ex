defmodule ArmchairMetropolist.UseCases.ManageInfrastructure do
  @moduledoc "Use case: place, remove, and query city infrastructure nodes."

  alias ArmchairMetropolist.Domain.Entities.{CityMap, Node}

  @doc """
  Place a new node of `type` at `(x, y)` on `city_map`.

  Validates, in order: the coordinates are in bounds, the type is a known
  node type, and the cell is not already occupied.
  """
  @spec place(CityMap.t(), integer(), integer(), atom()) ::
          {:ok, {CityMap.t(), Node.t()}}
          | {:error, :out_of_bounds | :occupied | :unknown_type}
  def place(city_map, x, y, type) do
    cond do
      not CityMap.in_bounds?(city_map, x, y) ->
        {:error, :out_of_bounds}

      type not in Node.types() ->
        {:error, :unknown_type}

      CityMap.occupied?(city_map, x, y) ->
        {:error, :occupied}

      true ->
        node = Node.new(x, y, type)
        {:ok, {CityMap.put_node(city_map, node), node}}
    end
  end

  @doc """
  Remove the node at `(x, y)` from `city_map`.
  """
  @spec demolish(CityMap.t(), integer(), integer()) ::
          {:ok, {CityMap.t(), String.t()}} | {:error, :empty}
  def demolish(city_map, x, y) do
    case CityMap.get_node(city_map, x, y) do
      nil ->
        {:error, :empty}

      node ->
        {:ok, {CityMap.delete_node(city_map, x, y), node.id}}
    end
  end
end
