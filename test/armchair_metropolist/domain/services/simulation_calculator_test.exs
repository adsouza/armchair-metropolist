defmodule ArmchairMetropolist.Domain.Services.SimulationCalculatorTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.{CityMap, Node}
  alias ArmchairMetropolist.Domain.Services.SimulationCalculator, as: Calc

  defp map_with(nodes) do
    Enum.reduce(nodes, CityMap.new(40, 30), &CityMap.put_node(&2, &1))
  end

  # Two residential blocks are sustainable on baseline capacity alone
  # (spec 4.2): power 30 <= 40, water 24 <= 40, waste 20 <= 40, traffic 12 <= 40.
  defp sustainable_city do
    map_with([Node.new(0, 0, :residential), Node.new(1, 0, :residential)])
  end

  # A city where water is only *slightly* short, so the resulting decay is
  # fractional and stays inside a single rounded health value.
  #
  #   power    supply 40 + 120*0.900 = 148.0   demand 25.0             -> 1.0
  #   water    supply 40 + 100*0.303 =  70.3   demand 20 + 3*18 = 74.0 -> 0.95
  #   waste    supply 40 + 3*8       =  64.0   demand 12 + 6    = 18.0 -> 1.0
  #   traffic  supply 40             =  40.0   demand 3 + 2 + 6 = 11.0 -> 1.0
  #
  # The power plant consumes water/waste/traffic, so its worst ratio is exactly
  # 0.95 (74.0 * 0.95 == 70.3) and its delta is -(1 - 0.95) * 6.0 = -0.30,
  # taking it from 90.0 to 89.7. round(90.0) == round(89.7) == 90 and the
  # status stays :online, so its display signature does not move.
  #
  # The water plant sits at "0:0" and the power plant at "1:0" deliberately.
  # Maps iterate in key order, so the water plant -- which regenerates from
  # 30.3 to 31.3 this tick -- is processed first. An implementation that
  # recomputed resource stats per node would then hand the power plant a water
  # supply of 71.3 (satisfaction 0.9635, health 89.78) instead of 70.3.
  defp sub_rounding_city do
    map_with([
      %Node{Node.new(0, 0, :water_plant) | health: 30.3, status: :degraded},
      %Node{Node.new(1, 0, :power_plant) | health: 90.0, status: :online},
      Node.new(0, 3, :park),
      Node.new(1, 3, :park),
      Node.new(2, 3, :park)
    ])
  end

  describe "baseline_capacity/0" do
    test "supplies 40 of every resource except labour and money, which have no free supply" do
      assert Calc.baseline_capacity() == %{
               power: 40.0,
               water: 40.0,
               waste: 40.0,
               traffic: 40.0,
               labour: 0.0,
               money: 0.0
             }
    end

    # The calculator derives its own `@resources` from this table's keys, so the table
    # *is* the calculator's vocabulary. Compared as sets, not as lists: `Node.resources/0`
    # is ordered for display and a map's key order is not a decision anyone made.
    test "covers exactly the resource vocabulary the domain publishes" do
      assert MapSet.new(Map.keys(Calc.baseline_capacity())) == MapSet.new(Node.resources())
    end
  end

  describe "resource_stats/1" do
    test "every flow resource carries nothing" do
      stats = Calc.resource_stats(sustainable_city())
      # Asserted explicitly so that folding the balance back into `supplied` later
      # cannot pass silently.
      for resource <- [:power, :water, :waste, :traffic, :labour] do
        assert Map.fetch!(stats, resource).carried == 0.0
      end
    end

    test "satisfaction is capped at 1.0 on surplus" do
      stats = Calc.resource_stats(sustainable_city())
      assert stats.power.satisfaction == 1.0
      assert stats.power.deficit == 0.0
    end

    test "satisfaction is the ratio on shortfall, and deficit is the gap" do
      # Four residential: power demand 60 vs baseline supply 40.
      map = map_with(for x <- 0..3, do: Node.new(x, 0, :residential))
      stats = Calc.resource_stats(map)
      assert_in_delta stats.power.supplied, 40.0, 0.001
      assert_in_delta stats.power.demanded, 60.0, 0.001
      assert_in_delta stats.power.deficit, 20.0, 0.001
      assert_in_delta stats.power.satisfaction, 40.0 / 60.0, 0.001
    end

    test "satisfaction is 1.0 when nothing demands the resource" do
      stats = Calc.resource_stats(CityMap.new(40, 30))
      assert stats.power.satisfaction == 1.0
      assert stats.power.demanded == 0.0
    end

    test "includes baseline capacity in supply" do
      stats = Calc.resource_stats(CityMap.new(40, 30))
      assert_in_delta stats.power.supplied, 40.0, 0.001
    end

    test "production scales with health but consumption does not" do
      # This asymmetry is the mechanism behind cascading failure. If
      # consumption also scaled, the simulation would silently self-stabilise
      # and the cascade test below would pass for the wrong reason.
      healthy = map_with([%Node{Node.new(0, 0, :power_plant) | health: 100.0}])
      broken = map_with([%Node{Node.new(0, 0, :power_plant) | health: 50.0}])

      assert_in_delta Calc.resource_stats(healthy).power.supplied, 160.0, 0.001
      assert_in_delta Calc.resource_stats(broken).power.supplied, 100.0, 0.001

      # A power plant consumes water 20 regardless of its own condition.
      assert_in_delta Calc.resource_stats(healthy).water.demanded, 20.0, 0.001
      assert_in_delta Calc.resource_stats(broken).water.demanded, 20.0, 0.001
    end

    # The housing requirement, stated directly rather than inferred from the tables.
    # An industrial block with nobody to staff it is the city shape this resource
    # exists to forbid.
    test "industry with no housing has no labour and decays at the full rate" do
      map = map_with([Node.new(0, 0, :industrial)])
      stats = Calc.resource_stats(map)

      assert stats.labour.demanded == 12.0
      assert stats.labour.supplied == 0.0
      assert stats.labour.satisfaction == 0.0

      {advanced, _delta} = Calc.advance_tick(map)
      industrial = CityMap.get_node(advanced, 0, 0)
      # -(1 - 0.0) * 6.0 from a starting 100.0
      assert_in_delta industrial.health, 94.0, 0.001
    end

    test "enough housing staffs the industry and stops the decay" do
      # 3 residential supply 12 labour, exactly the industrial block's demand.
      #
      # A bare industrial block plus 3 residential also draws more power and
      # water than baseline alone covers (industrial 40 + 3*15 = 85 power vs.
      # 40 baseline; industrial 25 + 3*12 = 61 water vs. 40 baseline) --
      # unrelated to labour, but enough to starve and decay the block anyway.
      # A power plant and water plant close those gaps so labour is the only
      # thing this fixture is testing; traffic and waste already clear
      # baseline without help.
      map =
        map_with([
          Node.new(0, 0, :industrial),
          Node.new(0, 2, :power_plant),
          Node.new(1, 2, :water_plant)
          | for(x <- 1..3, do: Node.new(x, 0, :residential))
        ])

      stats = Calc.resource_stats(map)

      # Pinning demanded, not just satisfaction, matters: satisfaction/2 treats
      # zero demand as automatically satisfied, so a mutated industrial labour
      # demand of 0.0 would still report satisfaction 1.0 here unless demanded
      # is checked directly.
      assert stats.labour.demanded == 12.0
      assert stats.labour.supplied == 12.0
      assert stats.labour.satisfaction == 1.0

      {advanced, _delta} = Calc.advance_tick(map)
      assert CityMap.get_node(advanced, 0, 0).health == 100.0
    end
  end

  describe "advance_tick/1 health arithmetic" do
    test "increments the tick by exactly one" do
      {map, _} = Calc.advance_tick(CityMap.new(40, 30))
      assert map.tick == 1
    end

    test "an untouched city keeps its balance across a tick" do
      {advanced, _delta} = Calc.advance_tick(sustainable_city())
      # Nothing produces or consumes money yet, so the grant is untouched.
      assert advanced.money == 500.0
    end

    test "regenerates by 1.0 when fully supplied" do
      map = map_with([%Node{Node.new(0, 0, :residential) | health: 50.0, status: :degraded}])
      {map, _} = Calc.advance_tick(map)
      assert_in_delta CityMap.get_node(map, 0, 0).health, 51.0, 0.001
    end

    test "decays proportionally to the unmet fraction" do
      # 4 residential: power satisfaction 40/60 = 0.6667, worst across
      # resources. delta = -(1 - 0.6667) * 6.0 = -2.0
      map = map_with(for x <- 0..3, do: Node.new(x, 0, :residential))
      {map, _} = Calc.advance_tick(map)
      assert_in_delta CityMap.get_node(map, 0, 0).health, 98.0, 0.01
    end

    test "clamps at 100.0 and never exceeds it" do
      map = sustainable_city()
      {map, _} = Calc.advance_tick(map)
      assert CityMap.get_node(map, 0, 0).health == 100.0
    end

    test "clamps at 0.0 and never goes negative" do
      # Total starvation: satisfaction 0 gives delta -6.0 per tick.
      map = map_with([%Node{Node.new(0, 0, :residential) | health: 1.0, status: :offline}])
      # Force a hard deficit by adding heavy consumers with no producers.
      map = Enum.reduce(1..30, map, &CityMap.put_node(&2, Node.new(&1, 5, :commercial)))
      {map, _} = Calc.advance_tick(map)
      assert CityMap.get_node(map, 0, 0).health == 0.0
    end

    test "worst ratio considers only resources the node consumes" do
      # A park consumes water and traffic but no power, so a total blackout
      # must leave it untouched.
      park = %Node{Node.new(0, 0, :park) | health: 80.0, status: :online}
      power_hogs = for x <- 1..10, do: Node.new(x, 1, :commercial)
      # Add water and traffic capacity so only power is short.
      supply = [Node.new(0, 5, :water_plant), Node.new(1, 5, :road_hub)]
      map = map_with([park | power_hogs] ++ supply)

      stats = Calc.resource_stats(map)
      assert stats.power.satisfaction < 1.0, "test setup should starve power"

      {map, _} = Calc.advance_tick(map)
      assert CityMap.get_node(map, 0, 0).health >= 80.0
    end

    test "derives status from the new health" do
      map = map_with([%Node{Node.new(0, 0, :residential) | health: 60.4, status: :online}])
      # Starve it hard so health drops below 60.
      map = Enum.reduce(1..30, map, &CityMap.put_node(&2, Node.new(&1, 5, :commercial)))
      {map, _} = Calc.advance_tick(map)
      node = CityMap.get_node(map, 0, 0)
      assert node.health < 60.0
      assert node.status == :degraded
    end

    test "computes resource stats once from the pre-tick map, whatever the node order" do
      # Insertion order must not matter: every node within a tick has to see
      # the same city-wide conditions.
      nodes = [
        %Node{Node.new(0, 0, :water_plant) | health: 30.3, status: :degraded},
        %Node{Node.new(1, 0, :power_plant) | health: 90.0, status: :online},
        Node.new(0, 3, :park),
        Node.new(1, 3, :park),
        Node.new(2, 3, :park)
      ]

      {forward, _} = Calc.advance_tick(map_with(nodes))
      {reverse, _} = Calc.advance_tick(map_with(Enum.reverse(nodes)))
      assert forward.nodes == reverse.nodes

      # And the figures must come from the *pre-tick* map. The water plant is
      # iterated before the power plant and regenerates 30.3 -> 31.3 on this
      # tick. Recomputing stats per node would give the power plant water
      # supply 71.3 (satisfaction 0.9635, delta -0.219, health 89.78) rather
      # than the pre-tick 70.3 (satisfaction 0.95, delta -0.30, health 89.7).
      assert_in_delta CityMap.get_node(forward, 0, 0).health, 31.3, 0.001
      assert_in_delta CityMap.get_node(forward, 1, 0).health, 89.7, 0.001
    end

    test "cascading failure: a failing plant drags the city down with it" do
      # One power plant supporting more load than baseline can carry.
      plant = %Node{Node.new(0, 0, :power_plant) | health: 30.0, status: :degraded}
      consumers = for x <- 1..8, do: Node.new(x, 0, :residential)

      support = [
        Node.new(0, 2, :water_plant),
        Node.new(1, 2, :industrial),
        Node.new(2, 2, :road_hub)
      ]

      initial = map_with([plant | consumers] ++ support)

      final =
        Enum.reduce(1..10, initial, fn _, acc ->
          {next, _delta} = Calc.advance_tick(acc)
          next
        end)

      plant_before = CityMap.get_node(initial, 0, 0).health
      plant_after = CityMap.get_node(final, 0, 0).health
      assert plant_after < plant_before, "the failing plant should keep degrading"

      consumer_after = CityMap.get_node(final, 1, 0).health
      assert consumer_after < 100.0, "consumers should degrade as supply collapses"

      assert Calc.resource_stats(final).power.satisfaction <
               Calc.resource_stats(initial).power.satisfaction,
             "power satisfaction should worsen as the plant decays"
    end
  end

  describe "advance_tick/1 delta semantics" do
    test "a stable, fully-supplied city emits an empty delta" do
      # Both nodes sit at 100.0 with full satisfaction, so health is clamped
      # and no display signature changes. This is the payoff of comparing
      # display state rather than raw structs.
      {_map, delta} = Calc.advance_tick(sustainable_city())
      assert delta == %{}
    end

    test "a starved city emits only the starved nodes" do
      starving = for x <- 0..3, do: Node.new(x, 0, :residential)
      # A park is insulated from the power shortage and should stay out.
      map = map_with([Node.new(0, 9, :park), Node.new(1, 9, :water_plant) | starving])
      {_map, delta} = Calc.advance_tick(map)

      assert Map.has_key?(delta, "0:0")
      refute Map.has_key?(delta, "0:9"), "the park does not consume power and should not change"
    end

    test "excludes a node whose health moves within the same rounded value" do
      # THE critical test: a health change too small to alter the rounded
      # display value must not enter the delta. A naive struct comparison
      # would include it and emit a full-grid delta every tick.
      #
      # Constructed via partial starvation so the decay is fractional.
      # 5 residential: power demand 75 vs baseline supply 40,
      # satisfaction 0.5333, delta = -(1 - 0.5333) * 6.0 = -2.8
      # A node at 90.4 goes to 87.6: round 90 -> 88, which DOES change.
      # So instead pick a starting health where the post-tick value rounds
      # identically. With decay -2.8, no single tick can round-trip; the
      # sub-rounding case therefore needs a gentler deficit.
      #
      # 5 residential + 1 power plant: power supply 40 + 120 = 160,
      # demand 75 + 0 = 75 -> power satisfied. Waste: supply 40,
      # demand 5*10 + 12 = 62, satisfaction 0.6452,
      # delta = -(1 - 0.6452) * 6.0 = -2.13. Still integral-crossing.
      #
      # Rather than contort the fixture, assert the property directly on
      # display_signature/1, which is what the delta membership rule uses.
      a = %Node{Node.new(0, 0, :residential) | health: 87.6, status: :online}
      b = %Node{a | health: 87.9}

      assert Node.display_signature(a) == Node.display_signature(b),
             "round(87.6) == round(87.9) == 88, so this movement must not enter the delta"

      # And prove the rule is actually what advance_tick/1 applies: a city
      # already clamped at 100.0 with full supply changes no signature.
      {_map, delta} = Calc.advance_tick(sustainable_city())
      assert delta == %{}

      # A genuine sub-rounding tick, which the note above thought too awkward
      # to construct. This is the assertion that discriminates the signature
      # rule from a naive whole-struct comparison: the power plant's health
      # really does move (90.0 -> 89.7), so `node == advanced` would be false
      # and it would be emitted -- but its rounded display value is unchanged,
      # so the delta must not contain it.
      initial = sub_rounding_city()
      {ticked, delta} = Calc.advance_tick(initial)

      plant_before = CityMap.get_node(initial, 1, 0)
      plant_after = CityMap.get_node(ticked, 1, 0)

      assert_in_delta plant_after.health, 89.7, 0.001
      refute plant_after.health == plant_before.health, "the health must genuinely move"

      assert Node.display_signature(plant_before) == Node.display_signature(plant_after),
             "round(90.0) == round(89.7) == 90 and the status stays :online"

      refute Map.has_key?(delta, "1:0"),
             "sub-rounding health movement must be excluded from the delta"

      # The water plant crosses a rounding boundary (30.3 -> 31.3) in the same
      # tick, so the delta is not trivially empty and the exclusion above is
      # a real filter rather than a no-op.
      assert Map.has_key?(delta, "0:0")
    end

    test "includes a node whose status flips at unchanged rounded health" do
      # The counterpart to the sub-rounding exclusion above, and the fourth delta
      # row in the spec. A node crosses the 60.0 status boundary while `round/1`
      # of its health is 60 on *both* sides, so only the status half of the
      # signature moves — and that alone must put it in the delta.
      #
      # Fixture arithmetic. Water demand is the plant's 20 plus 3 parks at 18 = 74;
      # supply is the 40 baseline plus the water plant's health-scaled output. A
      # water plant at 24.1333 gives 64.1333/74 = 0.86667 satisfaction, so the
      # power plant's delta is -(1 - 0.86667) * 6.0 = -0.8, taking 60.4 to 59.6.
      # Waste and traffic stay fully satisfied, so water is genuinely its worst.
      map =
        map_with([
          %Node{Node.new(1, 0, :power_plant) | health: 60.4, status: :online},
          %Node{Node.new(0, 0, :water_plant) | health: 24.1333, status: :degraded},
          Node.new(0, 3, :park),
          Node.new(1, 3, :park),
          Node.new(2, 3, :park)
        ])

      before = CityMap.get_node(map, 1, 0)
      {advanced, delta} = Calc.advance_tick(map)
      plant = CityMap.get_node(advanced, 1, 0)

      refute plant.health == before.health, "the fixture must actually move the plant's health"
      assert round(before.health) == 60
      assert round(plant.health) == 60, "rounded health must be unchanged on both sides"
      assert before.status == :online
      assert plant.status == :degraded, "the status half of the signature must be what moved"

      assert Map.has_key?(delta, plant.id),
             "a status flip at unchanged rounded health must still enter the delta"
    end

    test "delta keys are always a subset of the city's nodes" do
      map = map_with(for x <- 0..5, do: Node.new(x, 0, :residential))
      {new_map, delta} = Calc.advance_tick(map)
      assert MapSet.subset?(MapSet.new(Map.keys(delta)), MapSet.new(Map.keys(new_map.nodes)))
    end
  end

  describe "metrics/1" do
    test "reports tick, counts and resource stats together" do
      city = sustainable_city()
      metrics = Calc.metrics(%{city | tick: 4})
      assert metrics.tick == 4
      assert metrics.node_count == 2
      assert metrics.resources.power.satisfaction == 1.0
    end
  end

  describe "geography" do
    # Characterises the *absence* of a spatial mechanic rather than claiming one would
    # be wrong. Resources are pooled city-wide, so coordinates serve only as identity
    # and as somewhere to draw. docs/PLAYING.md tells players that layout is free,
    # which is a claim about this behaviour — so if adjacency, service radii or
    # distance costs are ever added, this test should fail and take that sentence with
    # it.
    test "layout does not affect the outcome: resources are pooled city-wide" do
      composition =
        [{:power_plant, 1}, {:water_plant, 1}, {:industrial, 1}, {:road_hub, 1}] ++
          List.duplicate({:residential, 1}, 5)

      types = Enum.map(composition, &elem(&1, 0))

      packed = Enum.with_index(types, fn type, i -> Node.new(rem(i, 3), div(i, 3), type) end)

      scattered =
        Enum.with_index(types, fn type, i ->
          if rem(i, 2) == 0, do: Node.new(i, 0, type), else: Node.new(39 - i, 29, type)
        end)

      run = fn nodes ->
        nodes
        |> map_with()
        |> then(&Enum.reduce(1..50, &1, fn _, city -> elem(Calc.advance_tick(city), 0) end))
        |> CityMap.nodes()
        |> Enum.map(&{&1.type, &1.health, &1.status})
        |> Enum.sort()
      end

      # Sorted by type/health/status rather than compared node-for-node: the two
      # layouts deliberately put the same types at different coordinates, so the ids
      # differ while everything the simulation cares about must not.
      assert run.(packed) == run.(scattered),
             "placement changed the outcome, so a spatial mechanic now exists — " <>
               "update the 'layout is free' claim in docs/PLAYING.md"
    end
  end
end
