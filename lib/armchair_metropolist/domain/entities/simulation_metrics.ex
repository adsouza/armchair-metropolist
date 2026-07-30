defmodule ArmchairMetropolist.Domain.Entities.SimulationMetrics do
  @moduledoc "Aggregate supply/demand and health figures for one tick."

  alias ArmchairMetropolist.Domain.Entities.CityMap

  @type resource_stats :: %{
          supplied: float(),
          demanded: float(),
          deficit: float(),
          satisfaction: float()
        }

  @type t :: %__MODULE__{
          tick: non_neg_integer(),
          resources: %{optional(atom()) => resource_stats()},
          node_count: non_neg_integer(),
          avg_health: float(),
          offline_count: non_neg_integer()
        }

  defstruct tick: 0, resources: %{}, node_count: 0, avg_health: 0.0, offline_count: 0

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
      offline_count: offline_count
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
end
