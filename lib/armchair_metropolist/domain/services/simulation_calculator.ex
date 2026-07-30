defmodule ArmchairMetropolist.Domain.Services.SimulationCalculator do
  @moduledoc """
  Pure domain calculations for advancing simulation state.

  The simulation is a deterministic function of the city map. One tick:

    1. `supply(r)` is the baseline capacity plus every node's
       *health-scaled* production of `r`.
    2. `demand(r)` is every node's *full* consumption of `r` — deliberately
       **not** scaled by health. Broken infrastructure still draws resources.
       This asymmetry is what makes failures cascade rather than self-correct.
    3. `satisfaction(r)` is `min(1.0, supply / demand)`, or `1.0` when nothing
       demands the resource.
    4. Each node looks at the satisfaction of only the resources it consumes
       and takes the worst of them.
    5. A fully supplied node regenerates `+1.0` health; a starved one loses
       `(1 - worst) * 6.0`.
    6. Health is clamped to `0.0..100.0` and status is re-derived from it.
    7. The tick counter advances by one.
    8. The returned delta holds only those nodes whose display signature
       (`{round(health), status}`) actually changed, so sub-pixel health
       movement does not push a full-grid diff to consumers.

  Resource statistics are computed **once from the pre-tick map** and applied
  to every node, so within a single tick all nodes see identical city-wide
  conditions and the outcome does not depend on map iteration order.
  """

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Entities.Node
  alias ArmchairMetropolist.Domain.Entities.SimulationMetrics

  @baseline_capacity %{power: 40.0, water: 40.0, waste: 40.0, traffic: 40.0}
  @resources Map.keys(@baseline_capacity)
  @no_resources Map.new(@resources, fn resource -> {resource, 0.0} end)

  @regen_per_tick 1.0
  @decay_per_tick 6.0
  @min_health 0.0
  @max_health 100.0

  @type delta :: %{optional(String.t()) => Node.t()}

  @doc """
  The city's free infrastructure-independent capacity, per resource.

  Every city starts able to support a small amount of development with no
  producers placed at all.
  """
  @spec baseline_capacity() :: %{Node.resource() => float()}
  def baseline_capacity, do: @baseline_capacity

  @doc """
  Supply, demand, deficit and satisfaction for every resource in the city.

  Always returns an entry for all four resources, even on an empty map.
  Production is scaled by producer health; consumption is not scaled at all.
  """
  @spec resource_stats(CityMap.t()) :: %{Node.resource() => SimulationMetrics.resource_stats()}
  def resource_stats(city_map) do
    nodes = CityMap.nodes(city_map)
    supply = total_supply(nodes)
    demand = total_demand(nodes)

    Map.new(@resources, fn resource ->
      supplied = Map.fetch!(supply, resource)
      demanded = Map.fetch!(demand, resource)

      stats = %{
        supplied: supplied,
        demanded: demanded,
        deficit: max(0.0, demanded - supplied),
        satisfaction: satisfaction(supplied, demanded)
      }

      {resource, stats}
    end)
  end

  @doc """
  Advance the city by one tick.

  Returns the new city map and a delta map of only the nodes whose display
  signature changed.
  """
  @spec advance_tick(CityMap.t()) :: {CityMap.t(), delta()}
  def advance_tick(city_map) do
    stats = resource_stats(city_map)

    {nodes, delta} =
      Enum.reduce(city_map.nodes, {%{}, %{}}, fn {key, node}, {nodes, delta} ->
        advanced = advance_node(node, stats)

        delta =
          if Node.display_signature(node) == Node.display_signature(advanced) do
            delta
          else
            Map.put(delta, key, advanced)
          end

        {Map.put(nodes, key, advanced), delta}
      end)

    {%{city_map | nodes: nodes, tick: city_map.tick + 1}, delta}
  end

  @doc """
  Build the aggregate metrics for the city in its current state.
  """
  @spec metrics(CityMap.t()) :: SimulationMetrics.t()
  def metrics(city_map) do
    SimulationMetrics.build(city_map, resource_stats(city_map))
  end

  # Baseline capacity plus health-scaled production from every node.
  defp total_supply(nodes) do
    Enum.reduce(nodes, @baseline_capacity, fn node, acc ->
      Enum.reduce(Node.effective_production(node), acc, &add_resource/2)
    end)
  end

  # Full consumption from every node, regardless of that node's health.
  defp total_demand(nodes) do
    Enum.reduce(nodes, @no_resources, fn node, acc ->
      node.type
      |> Node.consumption()
      |> Enum.reduce(acc, &add_resource/2)
    end)
  end

  defp add_resource({resource, amount}, acc) do
    Map.update(acc, resource, amount, &(&1 + amount))
  end

  defp satisfaction(_supplied, demanded) when demanded == 0.0, do: 1.0
  defp satisfaction(supplied, demanded), do: min(1.0, supplied / demanded)

  defp advance_node(node, stats) do
    health = clamp(node.health + health_delta(worst_satisfaction(node, stats)))
    %{node | health: health, status: Node.status_for(health)}
  end

  # Only the resources this node actually consumes constrain it. Starting the
  # reduction at 1.0 also covers a node type that consumes nothing.
  defp worst_satisfaction(node, stats) do
    node.type
    |> Node.consumption()
    |> Enum.reduce(1.0, fn {resource, _amount}, acc ->
      min(acc, Map.fetch!(stats, resource).satisfaction)
    end)
  end

  defp health_delta(worst) when worst >= 1.0, do: @regen_per_tick
  defp health_delta(worst), do: -(1.0 - worst) * @decay_per_tick

  defp clamp(health), do: health |> max(@min_health) |> min(@max_health)
end
