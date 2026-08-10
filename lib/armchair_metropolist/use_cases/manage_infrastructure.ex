defmodule ArmchairMetropolist.UseCases.ManageInfrastructure do
  @moduledoc "Use case: place, remove, and query city infrastructure nodes."

  alias ArmchairMetropolist.Domain.Entities.{CityMap, MunicipalBond, Node}
  alias ArmchairMetropolist.Domain.Services.SimulationCalculator

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

  On success, the returned map may have grown: see `CityMap.grow_if_crowded/1`.
  """
  @spec place(CityMap.t(), integer(), integer(), atom()) ::
          {:ok, {CityMap.t(), Node.t()}}
          | {:error,
             :out_of_bounds
             | :occupied
             | :unknown_type
             | :financing_required
             | :bond_default
             | :insufficient_funds}
  def place(city_map, x, y, type) do
    cost =
      if type in Node.types(),
        do: SimulationCalculator.construction_cost(city_map, type),
        else: nil

    cond do
      not CityMap.in_bounds?(city_map, x, y) ->
        {:error, :out_of_bounds}

      type not in Node.types() ->
        {:error, :unknown_type}

      CityMap.occupied?(city_map, x, y) ->
        {:error, :occupied}

      is_nil(city_map.municipal_bond) ->
        {:error, :financing_required}

      MunicipalBond.defaulted?(city_map.municipal_bond) or
          MunicipalBond.defaulted?(city_map.commercial_bond) ->
        {:error, :bond_default}

      city_map.money < cost ->
        {:error, :insufficient_funds}

      true ->
        node = Node.new(x, y, type)

        city_map =
          city_map
          |> CityMap.put_node(node)
          |> CityMap.debit(cost)
          # After the put, so the occupancy test counts the node just placed. Growth lives
          # here rather than in `CityMap.put_node/2` because `put_node/2` is a primitive
          # that sets one key: a growth policy inside it would reach every caller,
          # including fixtures that build a city of a chosen size, and there would then be
          # no way to build one at all.
          |> CityMap.grow_if_crowded()
          |> CityMap.increment_revision()

        {:ok, {city_map, node}}
    end
  end

  @doc """
  Remove the node at `(x, y)` from `city_map`. During opening planning this refunds the
  node's full construction cost; after the simulation begins it charges the flat
  demolition cost.

  Reports `:empty` before `:insufficient_funds`, for the same reason `place/4` reports
  occupancy first.
  """
  @spec demolish(CityMap.t(), integer(), integer()) ::
          {:ok, {CityMap.t(), String.t()}} | {:error, :empty | :insufficient_funds}
  def demolish(city_map, x, y) do
    node = CityMap.get_node(city_map, x, y)
    cost = SimulationCalculator.demolition_cost(city_map)

    cond do
      is_nil(node) ->
        {:error, :empty}

      not MunicipalBond.planning?(city_map.municipal_bond) and
          city_map.money < cost ->
        {:error, :insufficient_funds}

      true ->
        city_map =
          city_map
          |> CityMap.delete_node(x, y)
          |> settle_demolition(node, cost)
          |> CityMap.increment_revision()

        {:ok, {city_map, node.id}}
    end
  end

  defp settle_demolition(%CityMap{municipal_bond: bond} = city_map, node, cost) do
    if MunicipalBond.planning?(bond),
      do: CityMap.credit(city_map, Node.construction_cost(node.type)),
      else: CityMap.debit(city_map, cost)
  end
end
