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

  describe "by_type" do
    test "counts each type and includes types that are absent" do
      map =
        CityMap.new(40, 30)
        |> CityMap.put_node(Node.new(0, 0, :residential))
        |> CityMap.put_node(Node.new(1, 0, :residential))
        |> CityMap.put_node(Node.new(2, 0, :power_plant))

      by_type = SimulationMetrics.build(map, stats()).by_type

      assert by_type.residential.count == 2
      assert by_type.power_plant.count == 1

      # Absent types still get a row, so the legend does not reflow as a city grows.
      assert by_type.industrial.count == 0
      assert Enum.sort(Map.keys(by_type)) == Enum.sort(Node.types())
    end

    test "rated production is count x base and ignores health" do
      map =
        CityMap.new(40, 30)
        |> CityMap.put_node(%Node{Node.new(0, 0, :power_plant) | health: 25.0})
        |> CityMap.put_node(%Node{Node.new(1, 0, :power_plant) | health: 100.0})

      by_type = SimulationMetrics.build(map, stats()).by_type

      assert_in_delta by_type.power_plant.rated_production.power, 240.0, 0.001
    end

    test "actual production is health-scaled and diverges from rated" do
      # This divergence is the whole point of the legend: production scales with
      # health, consumption does not, so a damaged city shows supply falling against
      # steady demand.
      map =
        CityMap.new(40, 30)
        |> CityMap.put_node(%Node{Node.new(0, 0, :power_plant) | health: 25.0})
        |> CityMap.put_node(%Node{Node.new(1, 0, :power_plant) | health: 100.0})

      by_type = SimulationMetrics.build(map, stats()).by_type

      assert_in_delta by_type.power_plant.actual_production.power, 150.0, 0.001

      assert by_type.power_plant.actual_production.power <
               by_type.power_plant.rated_production.power,
             "a damaged producer must report less actual output than rated"
    end

    test "consumption is count x base and does not scale with health" do
      map =
        CityMap.new(40, 30)
        |> CityMap.put_node(%Node{Node.new(0, 0, :residential) | health: 1.0})
        |> CityMap.put_node(%Node{Node.new(1, 0, :residential) | health: 100.0})

      by_type = SimulationMetrics.build(map, stats()).by_type

      assert_in_delta by_type.residential.consumption.power, 30.0, 0.001
      assert_in_delta by_type.residential.consumption.water, 24.0, 0.001
    end

    test "a key is present only where the type touches that resource" do
      by_type = SimulationMetrics.build(CityMap.new(40, 30), stats()).by_type

      # A road hub produces traffic and consumes power and waste, but never water.
      assert Map.has_key?(by_type.road_hub.rated_production, :traffic)
      assert Map.has_key?(by_type.road_hub.consumption, :power)
      refute Map.has_key?(by_type.road_hub.consumption, :water)
      refute Map.has_key?(by_type.road_hub.rated_production, :water)
    end

    test "an empty city reports every type at zero rather than an empty map" do
      by_type = SimulationMetrics.build(CityMap.new(40, 30), stats()).by_type

      assert by_type.power_plant.count == 0

      # `===`, not `==`: these three come out of `scale/2`, which returns floats, and
      # `== 0.0` would also pass for an integer `0`. The type is the requirement.
      assert by_type.power_plant.rated_production.power === 0.0
      assert by_type.power_plant.actual_production.power === 0.0
      assert by_type.power_plant.consumption.water === 0.0
    end
  end
end
