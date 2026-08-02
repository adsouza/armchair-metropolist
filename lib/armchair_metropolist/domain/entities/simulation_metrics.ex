defmodule ArmchairMetropolist.Domain.Entities.SimulationMetrics do
  @moduledoc "Aggregate supply/demand and health figures for one tick."

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Entities.Node

  @type resource_stats :: %{
          supplied: float(),
          demanded: float(),
          deficit: float(),
          satisfaction: float()
        }

  @typedoc """
  One type's contribution. A key is present in the inner maps only where that node
  type's base tables mention the resource, so a missing key means "does not interact"
  while a present `0.0` means "nets to zero" — the legend renders those differently.
  """
  @type type_stats :: %{
          count: non_neg_integer(),
          rated_production: %{Node.resource() => float()},
          actual_production: %{Node.resource() => float()},
          consumption: %{Node.resource() => float()}
        }

  @type t :: %__MODULE__{
          tick: non_neg_integer(),
          resources: %{optional(atom()) => resource_stats()},
          node_count: non_neg_integer(),
          avg_health: float(),
          offline_count: non_neg_integer(),
          by_type: %{Node.node_type() => type_stats()}
        }

  defstruct tick: 0,
            resources: %{},
            node_count: 0,
            avg_health: 0.0,
            offline_count: 0,
            by_type: %{}

  @doc """
  Build a SimulationMetrics struct from a city map and resource statistics.

  Aggregates node-level figures: count, average health, and offline count.
  Resource statistics are passed through unchanged.
  """
  def build(city_map, resources) do
    nodes = CityMap.nodes(city_map)
    node_count = length(nodes)

    avg_health = calculate_avg_health(nodes)
    offline_count = count_offline_nodes(nodes)

    %__MODULE__{
      tick: city_map.tick,
      resources: resources,
      node_count: node_count,
      avg_health: avg_health,
      offline_count: offline_count,
      by_type: build_by_type(nodes)
    }
  end

  defp calculate_avg_health([]), do: 0.0

  defp calculate_avg_health(nodes) do
    sum = Enum.reduce(nodes, 0.0, fn node, acc -> acc + node.health end)
    sum / length(nodes)
  end

  defp count_offline_nodes(nodes) do
    Enum.count(nodes, &(&1.status == :offline))
  end

  # Every type gets an entry, present or not, so the legend renders a stable set of
  # rows. Rated and actual are kept apart rather than reduced to one figure: production
  # scales with health and consumption does not, and that divergence is what makes a
  # collapse visible.
  defp build_by_type(nodes) do
    grouped = Enum.group_by(nodes, & &1.type)

    Map.new(Node.types(), fn type ->
      of_type = Map.get(grouped, type, [])

      {type,
       %{
         count: length(of_type),
         rated_production: scale(Node.production(type), length(of_type)),
         actual_production: sum_actual_production(type, of_type),
         consumption: scale(Node.consumption(type), length(of_type))
       }}
    end)
  end

  defp scale(table, count) do
    Map.new(table, fn {resource, amount} -> {resource, amount * count} end)
  end

  # Keyed off the type's *base* production table rather than the nodes, so the keys are
  # the same whether or not any are placed.
  defp sum_actual_production(type, nodes) do
    type
    |> Node.production()
    |> Map.new(fn {resource, _base} ->
      total =
        Enum.reduce(nodes, 0.0, fn node, acc ->
          acc + Map.get(Node.effective_production(node), resource, 0.0)
        end)

      {resource, total}
    end)
  end
end
