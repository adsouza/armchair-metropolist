defmodule ArmchairMetropolist.Domain.Entities.SimulationMetricsTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.{CityMap, Node, SimulationMetrics}

  defp stats, do: %{power: %{supplied: 1.0, demanded: 1.0, deficit: 0.0, satisfaction: 1.0}}

  test "aggregates node count, average health and offline count" do
    map =
      CityMap.new(40, 30)
      |> CityMap.put_node(%Node{Node.new(0, 0, :residential) | health: 100.0, status: :online})
      |> CityMap.put_node(%Node{Node.new(1, 0, :residential) | health: 50.0, status: :degraded})
      |> CityMap.put_node(%Node{Node.new(2, 0, :residential) | health: 10.0, status: :offline})

    metrics = SimulationMetrics.build(%{map | tick: 7}, stats())

    assert metrics.tick == 7
    assert metrics.node_count == 3
    assert_in_delta metrics.avg_health, 53.3333, 0.001
    assert metrics.offline_count == 1
    assert metrics.resources == stats()
  end

  # An empty grid is the default startup state (spec 6.4 hydration fallback),
  # so avg_health must not divide by zero.
  test "an empty city yields zero average health rather than raising" do
    metrics = SimulationMetrics.build(CityMap.new(40, 30), stats())
    assert metrics.node_count == 0
    assert metrics.avg_health === 0.0
    assert metrics.offline_count == 0
  end
end
