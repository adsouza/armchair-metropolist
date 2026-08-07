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

  # The LiveView receives metrics and never the city map, so without this field
  # the treasury balance cannot reach the page at all.
  test "carries the city's treasury balance" do
    city_map = %{CityMap.new(40, 30) | money: 275.0}
    metrics = SimulationMetrics.build(city_map, %{})
    assert metrics.money == 275.0
  end

  # An empty grid is the default startup state (spec 6.4 hydration fallback),
  # so avg_health must not divide by zero.
  test "an empty city yields zero average health rather than raising" do
    metrics = SimulationMetrics.build(CityMap.new(40, 30), stats())
    assert metrics.node_count == 0
    assert metrics.avg_health === 0.0
    assert metrics.offline_count == 0
  end

  test "defaults to no amenity when none is supplied" do
    metrics = SimulationMetrics.build(CityMap.new(40, 30), %{})

    assert metrics.amenity == 1.0
    assert metrics.amenity_marginal_labour == 0.0
    assert metrics.amenity_labour == 0.0
  end

  test "carries the derived figures it is given" do
    metrics =
      SimulationMetrics.build(CityMap.new(40, 30), %{}, %{
        amenity: 1.75,
        amenity_marginal_labour: 5.0,
        amenity_labour: 15.0,
        stalled: true
      })

    assert metrics.amenity == 1.75
    assert metrics.amenity_marginal_labour == 5.0
    assert metrics.amenity_labour == 15.0

    # `true` rather than `false`: the struct default is `false`, so a build that dropped
    # this key on the floor would still satisfy a `refute`.
    assert metrics.stalled
  end

  # A partial derived map is a programming error, not a request for defaults: the default
  # applies to the argument as a whole, so silently filling one missing key would let a
  # caller that computed three figures out of four ship an amenity-free labour total.
  #
  # Exactly one key is withheld, and it is named in the assertion. With two or more
  # missing, this passes for whichever one `build/3` happens to fetch first and says
  # nothing about the others.
  #
  # Built with `Map.new/1` rather than a map literal: a literal missing a required key is
  # something Elixir's type checker now catches statically — precisely the incompleteness
  # this test exists to force at runtime — so it emits a compile-time type-warning that a
  # literal built through `Map.new/1` does not. The checker cannot see through the call, and
  # the resulting map is byte-identical to the literal it replaces, so the raise this test
  # is pinning is unaffected.
  test "raises rather than defaulting when the derived map is missing a figure" do
    assert_raise KeyError, ~r/:amenity_labour/, fn ->
      SimulationMetrics.build(
        CityMap.new(40, 30),
        %{},
        Map.new(amenity: 1.75, amenity_marginal_labour: 5.0, stalled: false)
      )
    end
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

      assert_in_delta by_type.power_plant.rated_capacity.power, 240.0, 0.001
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

      assert_in_delta by_type.power_plant.actual_capacity.power, 150.0, 0.001

      assert by_type.power_plant.actual_capacity.power <
               by_type.power_plant.rated_capacity.power,
             "a damaged producer must report less actual output than rated"
    end

    test "consumption is count x base and does not scale with health" do
      map =
        CityMap.new(40, 30)
        |> CityMap.put_node(%Node{Node.new(0, 0, :residential) | health: 1.0})
        |> CityMap.put_node(%Node{Node.new(1, 0, :residential) | health: 100.0})

      by_type = SimulationMetrics.build(map, stats()).by_type

      assert_in_delta by_type.residential.load.power, 30.0, 0.001
      assert_in_delta by_type.residential.load.water, 24.0, 0.001
    end

    test "a key is present only where the type touches that resource" do
      by_type = SimulationMetrics.build(CityMap.new(40, 30), stats()).by_type

      # A transit hub produces traffic and consumes power and waste, but never water.
      assert Map.has_key?(by_type.transit_hub.rated_capacity, :traffic)
      assert Map.has_key?(by_type.transit_hub.load, :power)
      refute Map.has_key?(by_type.transit_hub.load, :water)
      refute Map.has_key?(by_type.transit_hub.rated_capacity, :water)
    end

    test "an empty city reports every type at zero rather than an empty map" do
      by_type = SimulationMetrics.build(CityMap.new(40, 30), stats()).by_type

      assert by_type.power_plant.count == 0

      # `===`, not `==`: these three come out of `scale/2`, which returns floats, and
      # `== 0.0` would also pass for an integer `0`. The type is the requirement.
      assert by_type.power_plant.rated_capacity.power === 0.0
      assert by_type.power_plant.actual_capacity.power === 0.0
      assert by_type.power_plant.load.water === 0.0
    end
  end

  describe "housing_alive" do
    test "false when every residential block sits at exactly zero health" do
      # A count-based reading would say true here — the houses are still standing.
      # This is the common death, so a reading that misses it is useless.
      city = city_with([%Node{Node.new(0, 0, :residential) | health: 0.0, status: :offline}])

      refute build(city).housing_alive
    end

    test "true when one residential block has any health at all" do
      # health 5.0 is `:offline`, and still supplies 0.25 labour. A status-based
      # reading would say false here.
      city = city_with([%Node{Node.new(0, 0, :residential) | health: 5.0, status: :offline}])

      assert build(city).housing_alive
    end

    test "false when the city has no residential blocks" do
      city = city_with([Node.new(0, 0, :power_plant)])

      refute build(city).housing_alive
    end
  end

  describe "bankrupt" do
    test "true just below the cheapest action" do
      # 9.0 and 10.0 rather than 0.0 and something large: a fixture at 0.0 cannot tell
      # `money < 10` apart from `money == 0`, and these two straddle the real boundary.
      assert build(%{CityMap.new(40, 30) | money: 9.0}).bankrupt
    end

    test "false at exactly the cheapest action" do
      refute build(%{CityMap.new(40, 30) | money: 10.0}).bankrupt
    end
  end

  describe "game_over?/1" do
    test "true only when the city is both stalled and bankrupt" do
      assert SimulationMetrics.game_over?(%SimulationMetrics{stalled: true, bankrupt: true})
    end

    test "false for a stalled city that can still afford to act" do
      # This is the state a rescue is possible from, so calling it game over would be
      # a false claim. Also what an `or` in place of the `and` would break.
      refute SimulationMetrics.game_over?(%SimulationMetrics{stalled: true, bankrupt: false})
    end

    test "false for a broke city that is still running" do
      refute SimulationMetrics.game_over?(%SimulationMetrics{stalled: false, bankrupt: true})
    end
  end

  # Helpers — put these at the bottom of the module, beside any existing private helpers.
  defp city_with(nodes) do
    Enum.reduce(nodes, CityMap.new(40, 30), &CityMap.put_node(&2, &1))
  end

  defp build(city_map) do
    SimulationMetrics.build(city_map, %{})
  end
end
