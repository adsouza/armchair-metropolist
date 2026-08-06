defmodule ArmchairMetropolist.UseCases.ManageInfrastructure do
  @moduledoc "Use case: place, remove, and query city infrastructure nodes."

  alias ArmchairMetropolist.Domain.Entities.{CityMap, Node}

  @doc """
  Place a new node of `type` at `(x, y)` on `city_map`.

  Validates, in order: the coordinates are in bounds, the type is a known node type, the
  cell is not already occupied, and the treasury covers the type's construction cost.

  **Two of those orderings are load-bearing.** `unknown_type` must stay above the cost
  check because `Node.construction_cost/1` is a `Map.fetch!` — an unknown type reaching it
  raises `KeyError` inside a `GenServer.call` instead of returning an error tuple, which
  takes the engine down and rolls the city back to its last checkpoint. And
  `insufficient_funds` goes last, so a click on an occupied cell reports occupancy rather
  than reporting that you are broke about a build that was never possible there.
  """
  @spec place(CityMap.t(), integer(), integer(), atom()) ::
          {:ok, {CityMap.t(), Node.t()}}
          | {:error, :out_of_bounds | :occupied | :unknown_type | :insufficient_funds}
  def place(city_map, x, y, type) do
    cond do
      not CityMap.in_bounds?(city_map, x, y) ->
        {:error, :out_of_bounds}

      type not in Node.types() ->
        {:error, :unknown_type}

      CityMap.occupied?(city_map, x, y) ->
        {:error, :occupied}

      city_map.money < Node.construction_cost(type) ->
        {:error, :insufficient_funds}

      true ->
        node = Node.new(x, y, type)

        city_map =
          city_map
          |> CityMap.put_node(node)
          |> CityMap.debit(Node.construction_cost(type))

        {:ok, {city_map, node}}
    end
  end

  @doc """
  Remove the node at `(x, y)` from `city_map`, charging the flat demolition cost.

  Reports `:empty` before `:insufficient_funds`, for the same reason `place/4` reports
  occupancy first.
  """
  @spec demolish(CityMap.t(), integer(), integer()) ::
          {:ok, {CityMap.t(), String.t()}} | {:error, :empty | :insufficient_funds}
  def demolish(city_map, x, y) do
    cond do
      is_nil(CityMap.get_node(city_map, x, y)) ->
        {:error, :empty}

      city_map.money < Node.demolition_cost() ->
        {:error, :insufficient_funds}

      true ->
        node = CityMap.get_node(city_map, x, y)

        city_map =
          city_map
          |> CityMap.delete_node(x, y)
          |> CityMap.debit(Node.demolition_cost())

        {:ok, {city_map, node.id}}
    end
  end
end
