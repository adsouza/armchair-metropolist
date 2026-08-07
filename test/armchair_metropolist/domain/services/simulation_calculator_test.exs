defmodule ArmchairMetropolist.Domain.Services.SimulationCalculatorTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.{CityMap, Node}
  alias ArmchairMetropolist.Domain.Services.SimulationCalculator, as: Calc

  defp map_with(nodes) do
    Enum.reduce(nodes, CityMap.new(40, 30), &CityMap.put_node(&2, &1))
  end

  # Helpers — added beside `map_with/1`. `map_with/1` is not reused: these need
  # per-node health and status set, and threading that through it would change a
  # helper five other fixtures depend on.
  defp houses(count, health) do
    Enum.reduce(0..(count - 1)//1, CityMap.new(40, 30), fn x, map ->
      CityMap.put_node(map, %Node{
        Node.new(x, 0, :residential)
        | health: health,
          status: Node.status_for(health)
      })
    end)
  end

  defp dead_houses(count), do: %{houses(count, 0.0) | money: 0.0}

  # Two residential blocks are sustainable on baseline capacity alone
  # (spec 4.2): power 30 <= 40, water 24 <= 40, waste 20 <= 40, traffic 12 <= 40.
  defp sustainable_city do
    map_with([Node.new(0, 0, :residential), Node.new(1, 0, :residential)])
  end

  # A city where water is only *slightly* short, so the resulting decay is
  # fractional and stays inside a single rounded health value.
  #
  #   power    supply 40 + 120*0.900 = 148.0   demand 25 + 15 = 40.0        -> 1.0
  #   water    supply 40 + 100*0.417 =  81.7   demand 20 + 3*18 + 12 = 86.0 -> 0.95
  #   waste    supply 40 + 3*8       =  64.0   demand 12 + 6 + 10 = 28.0    -> 1.0
  #   traffic  supply 40             =  40.0   demand 3 + 2 + 6 + 6 = 17.0  -> 1.0
  #   labour   supply 1*5.0 * 2.0    =  10.0   demand 1 + 1 + 3*1 = 5.0     -> 1.0
  #
  # The ×2.0 on labour is the park amenity at its cap: 3 parks to 1 residential is a ratio
  # of 3.0, clamped to @max_amenity_ratio = 1.0, so the multiplier is 1 + k*1.0 = 2.0.
  # Supply is 10.0, not 5.0 — do not "correct" this back to a knife-edge 5.0/5.0 margin.
  # Nothing downstream can catch that error, because satisfaction saturates at 1.0 either
  # way.
  #
  # The residential block is not decoration: since everything but housing is staffed
  # (2026-08-05) this city draws 5 labour, and without a house to supply it labour
  # satisfaction is 0.0 and *both* plants take the full 6.0 decay — which destroys the
  # sub-rounding movement this fixture exists to produce. Its water draw of 12 is why the
  # water plant sits at 41.7 rather than 30.3: water demand is 86.0 now, and 0.95 of that
  # is 81.7 = 40 baseline + 41.7 health-scaled.
  #
  # Money is absent from the table because it is not meant to bind: demand is the water
  # plant's 5 plus 3 per park = 14, against a supply of 1 from the residential block,
  # covered as `carried` by `CityMap.new/2`'s default 150.0 grant.
  #
  # The power plant consumes water/waste/traffic/labour, so its worst ratio is exactly
  # 0.95 (86.0 * 0.95 == 81.7) and its delta is -(1 - 0.95) * 6.0 = -0.30, taking it from
  # 90.0 to 89.7. round(90.0) == round(89.7) == 90 and the status stays :online, so its
  # display signature does not move.
  #
  # The water plant sits at "0:0" and the power plant at "1:0" deliberately. Maps iterate
  # in key order, so the water plant -- which regenerates from 41.7 to 42.7 this tick --
  # is processed first. An implementation that recomputed resource stats per node would
  # then hand the power plant a water supply of 82.7 (satisfaction 0.9616, health 89.77)
  # instead of 81.7.
  defp sub_rounding_city do
    map_with([
      %Node{Node.new(0, 0, :water_plant) | health: 41.7, status: :degraded},
      %Node{Node.new(1, 0, :power_plant) | health: 90.0, status: :online},
      Node.new(0, 3, :park),
      Node.new(1, 3, :park),
      Node.new(2, 3, :park),
      Node.new(5, 5, :residential)
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
      # 3 residential supply 15 labour against a demand of 14: the industrial block's
      # 12, plus 1 each for the power and water plants below. The margin is deliberate
      # slack — there is no residential count that makes this exact, because housing
      # comes in units of 5.
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
      assert stats.labour.demanded == 14.0
      assert stats.labour.supplied == 15.0
      assert stats.labour.satisfaction == 1.0

      {advanced, _delta} = Calc.advance_tick(map)
      assert CityMap.get_node(advanced, 0, 0).health == 100.0
    end

    # Finding 1's fix: the legend's totals cell reads `flow_satisfaction`, not
    # `satisfaction`, precisely so a treasury covering a deficit cannot make the
    # cell's two halves (supplied/demanded) contradict its own percentage.
    test "a treasury covering a deficit makes flow_satisfaction and satisfaction diverge" do
      # One park: money demand 3/tick, no income. A treasury of 100 fully covers it
      # (available 100 vs demand 3), but the flow itself is 0 supplied against 3
      # demanded.
      map = %{map_with([Node.new(0, 0, :park)]) | money: 100.0}
      stats = Calc.resource_stats(map)

      assert stats.money.supplied == 0.0
      assert stats.money.demanded == 3.0
      assert stats.money.carried == 100.0
      assert stats.money.satisfaction == 1.0
      assert stats.money.flow_satisfaction == 0.0
    end

    test "flow_satisfaction equals satisfaction for every flow resource" do
      # Four residential: power demand 60 vs baseline supply 40, so power is
      # genuinely short. Every flow resource carries 0.0, so the two figures have
      # no basis on which to differ.
      map = map_with(for x <- 0..3, do: Node.new(x, 0, :residential))
      stats = Calc.resource_stats(map)

      for resource <- [:power, :water, :waste, :traffic, :labour] do
        entry = Map.fetch!(stats, resource)
        assert entry.flow_satisfaction == entry.satisfaction
      end
    end

    test "staffing demand is not scaled by health" do
      healthy = map_with([Node.new(0, 0, :transit_hub)])
      dead = map_with([%Node{Node.new(0, 0, :transit_hub) | health: 0.0, status: :offline}])

      # Asserted in both states deliberately. Only the dead case can fail if staffing
      # were health-scaled, and only the healthy case proves the figure is 2.0 at all.
      assert Calc.resource_stats(healthy).labour.demanded == 2.0
      assert Calc.resource_stats(dead).labour.demanded == 2.0
    end

    test "a construction charge does not enter money demand" do
      alias ArmchairMetropolist.UseCases.ManageInfrastructure

      before = map_with([Node.new(0, 0, :park)])
      {:ok, {after_place, _}} = ManageInfrastructure.place(before, 1, 1, :park)

      # Positive case first: money demand does track upkeep, so this cannot pass by
      # reading zero out of a broken path. Two parks draw 3 each.
      #
      # The second assertion is the whole test. Exact equality on 6.0 means the 20.0
      # build charge is provably absent — demand is a per-tick flow, the charge is a
      # withdrawal from a stock, and folding it in would corrupt the legend's totals
      # cell, which is the defect the money design's amendment exists to fix. A
      # `refute … == 26.0` alongside it would be decoration: dead the moment the
      # equality above passes.
      assert Calc.resource_stats(before).money.demanded == 3.0
      assert Calc.resource_stats(after_place).money.demanded == 6.0
    end
  end

  describe "park amenity" do
    defp labour_supplied(city) do
      city |> Calc.resource_stats() |> Map.fetch!(:labour) |> Map.fetch!(:supplied)
    end

    # `housing` residential blocks and `parks` parks, all at full health unless
    # overridden. Coordinates are irrelevant to the simulation and only need to be
    # distinct, so the two types sit on separate rows.
    defp housing_and_parks(housing, parks, opts \\ []) do
      housing_health = Keyword.get(opts, :housing_health, 100.0)
      park_health = Keyword.get(opts, :park_health, 100.0)

      residential =
        for i <- 1..housing//1 do
          %Node{
            Node.new(i, 0, :residential)
            | health: housing_health,
              status: Node.status_for(housing_health)
          }
        end

      park_nodes =
        for i <- 1..parks//1 do
          %Node{
            Node.new(i, 1, :park)
            | health: park_health,
              status: Node.status_for(park_health)
          }
        end

      map_with(residential ++ park_nodes)
    end

    test "no parks leaves labour supply unmultiplied" do
      assert labour_supplied(housing_and_parks(6, 0)) == 30.0
    end

    test "one park per housing block is the maximum, x2.0" do
      assert labour_supplied(housing_and_parks(6, 6)) == 60.0
    end

    test "past parity the multiplier is capped" do
      # Kills a missing `min/2`: uncapped this would be 6 residential x 5 x (1 + 20/6).
      assert labour_supplied(housing_and_parks(6, 20)) == 60.0
    end

    test "below the cap each park adds a constant L*k labour, whatever the city size" do
      # The identity that pins L, k, the legend's figure and the balance work together.
      # Asserted over several shapes rather than one, because a single pair is also
      # satisfied by formulas that are not this one. Expect 45.0, 80.0, 75.0, 50.0.
      for {housing, parks} <- [{6, 3}, {12, 4}, {10, 5}, {8, 2}] do
        assert labour_supplied(housing_and_parks(housing, parks)) ==
                 5.0 * housing + 5.0 * parks,
               "expected LH + LkP for H=#{housing} P=#{parks}"
      end
    end

    test "no housing means no labour, whatever the park count, and does not raise" do
      # Two claims: the design property, and that the zero-housing branch is guarded.
      # Erlang raises ArithmeticError on 0.0/0.0, so an unguarded division fails here
      # rather than returning a wrong number.
      assert labour_supplied(housing_and_parks(0, 8)) == 0.0
    end

    test "the amenity is health-weighted on the park side" do
      assert labour_supplied(housing_and_parks(8, 4)) == 60.0
      # 4 parks at half health is 2.0 effective parks against 8 housing: ratio 0.25,
      # so 40.0 base x 1.25.
      assert labour_supplied(housing_and_parks(8, 4, park_health: 50.0)) == 50.0
    end

    test "the amenity is health-weighted on the housing side" do
      # 8 blocks at half health supply 20 labour and count as 4.0 effective housing,
      # so 4 parks is parity and the multiplier caps at x2.0.
      assert labour_supplied(housing_and_parks(8, 4, housing_health: 50.0)) == 40.0
    end

    test "metrics carries the multiplier and the labour one more park would add" do
      # 4 housing, 2 parks: ratio 0.5, so multiplier 1.5 and one more park is worth L*k.
      metrics = Calc.metrics(housing_and_parks(4, 2))

      assert metrics.amenity == 1.5
      assert metrics.amenity_marginal_labour == 5.0
    end

    test "the marginal figure is zero once parks have reached housing" do
      assert Calc.metrics(housing_and_parks(4, 4)).amenity_marginal_labour == 0.0
    end

    test "the marginal figure is the true difference where a park crosses the cap" do
      # Three healthy parks plus a half-dead one is 3.5 effective against 4 housing,
      # so ratio 0.875. One more park would reach 1.125 — above the cap — so the gain
      # is only the 0.125 of ratio that fits underneath it, not the full L*k of 5.0.
      #
      # This is the case the "L*k, or zero when saturated" shortcut gets wrong, and so
      # the case that justifies computing an actual difference.
      half_dead = %Node{Node.new(9, 9, :park) | health: 50.0, status: :degraded}
      city = CityMap.put_node(housing_and_parks(4, 3), half_dead)

      assert Calc.metrics(city).amenity_marginal_labour == 2.5
    end

    test "metrics carries what the placed parks contribute, which is not the marginal" do
      # 4 housing, 3 parks: ratio 0.75, below the cap, so the placed parks are worth
      # L*k each. Labour supply is 35.0 with them and 20.0 without.
      metrics = Calc.metrics(housing_and_parks(4, 3))

      assert metrics.amenity_labour == 15.0

      # The two figures answer different questions and must not be conflated: below the
      # cap the marginal is one park's worth while the total is three parks' worth.
      assert metrics.amenity_marginal_labour == 5.0
    end

    test "the placed-parks figure is bounded by the housing once past the cap" do
      # 2 housing, 3 parks: ratio 1.5, clamped to 1.0, so the amenity is L*k*housing = 10
      # rather than L*k*parks = 15. Labour supply is 20.0 with the parks and 10.0 without.
      # This is the case a `L*k*parks` shortcut gets wrong, so it is why the figure is
      # computed as a real difference.
      metrics = Calc.metrics(housing_and_parks(2, 3))

      assert metrics.amenity_labour == 10.0

      # And here the marginal is zero while the total is at its largest — the clearest
      # demonstration that one cannot be derived from the other.
      assert metrics.amenity_marginal_labour == 0.0
    end

    test "no parks means the placed-parks figure is zero, not the whole labour supply" do
      # Guards the subtraction's second term: with no parks to remove, both sides of the
      # difference are the same city, so a sign slip or a swapped operand shows up here as
      # the full 20.0 of housing supply being attributed to an amenity that is absent.
      assert Calc.metrics(housing_and_parks(4, 0)).amenity_labour == 0.0
    end
  end

  describe "advance_tick/1 health arithmetic" do
    test "increments the tick by exactly one" do
      {map, _} = Calc.advance_tick(CityMap.new(40, 30))
      assert map.tick == 1
    end

    test "an untouched city keeps its balance across a tick" do
      {advanced, _delta} = Calc.advance_tick(sustainable_city())
      # Two residential produce money now (1.0 each) and consume none, so the
      # grant grows rather than staying put.
      #
      # Written as grant + 2.0 rather than as the sum. The literal was 152.0, which is
      # the grant *derived* — a search for the grant's own value does not find it, and
      # it is what broke when the grant moved from 150 to 400. The income is the claim
      # here; the starting balance is incidental.
      assert advanced.money == CityMap.opening_grant() + 2.0
    end

    test "an unpayable upkeep starves the consumer once the treasury is empty" do
      # One park: upkeep 3/tick, no income. Start it broke rather than simulating
      # 167 ticks of drain.
      map = %{map_with([Node.new(0, 0, :park)]) | money: 0.0}
      stats = Calc.resource_stats(map)

      assert stats.money.demanded == 3.0
      assert stats.money.carried == 0.0
      assert stats.money.satisfaction == 0.0

      {advanced, _delta} = Calc.advance_tick(map)
      assert advanced.money == 0.0
      assert CityMap.get_node(advanced, 0, 0).health < 100.0
    end

    test "surplus income accumulates in the treasury" do
      # One commercial (+30) and one park (-3), starting from a known balance.
      map = %{map_with([Node.new(0, 0, :commercial), Node.new(1, 0, :park)]) | money: 100.0}
      {advanced, _delta} = Calc.advance_tick(map)
      assert_in_delta advanced.money, 127.0, 0.001
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
      #
      # The hogs are `residential`, not `commercial`: a park draws labour now, and
      # `commercial` draws 8 each, so a commercial-only city has labour satisfaction 0.0
      # and the park would decay on labour rather than being untouched — passing the
      # blackout premise while testing nothing. `residential` draws power and supplies
      # the labour instead.
      park = %Node{Node.new(0, 0, :park) | health: 80.0, status: :online}
      power_hogs = for x <- 1..10, do: Node.new(x, 1, :residential)
      # Add water and traffic capacity so only power is short.
      supply = [Node.new(0, 5, :water_plant), Node.new(1, 5, :transit_hub)]
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
        %Node{Node.new(0, 0, :water_plant) | health: 41.7, status: :degraded},
        %Node{Node.new(1, 0, :power_plant) | health: 90.0, status: :online},
        Node.new(0, 3, :park),
        Node.new(1, 3, :park),
        Node.new(2, 3, :park),
        Node.new(5, 5, :residential)
      ]

      {forward, _} = Calc.advance_tick(map_with(nodes))
      {reverse, _} = Calc.advance_tick(map_with(Enum.reverse(nodes)))
      assert forward.nodes == reverse.nodes

      # And the figures must come from the *pre-tick* map. The water plant is
      # iterated before the power plant and regenerates 41.7 -> 42.7 on this
      # tick. Recomputing stats per node would give the power plant water
      # supply 82.7 (satisfaction 0.9616, delta -0.230, health 89.77) rather
      # than the pre-tick 81.7 (satisfaction 0.95, delta -0.30, health 89.7).
      assert_in_delta CityMap.get_node(forward, 0, 0).health, 42.7, 0.001
      assert_in_delta CityMap.get_node(forward, 1, 0).health, 89.7, 0.001
    end

    test "cascading failure: a failing plant drags the city down with it" do
      # One power plant supporting more load than baseline can carry.
      plant = %Node{Node.new(0, 0, :power_plant) | health: 30.0, status: :degraded}
      consumers = for x <- 1..8, do: Node.new(x, 0, :residential)

      support = [
        Node.new(0, 2, :water_plant),
        Node.new(1, 2, :industrial),
        Node.new(2, 2, :transit_hub)
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

      # The water plant crosses a rounding boundary (41.7 -> 42.7) in the same
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
      # Fixture arithmetic. Water demand is the plant's 20, 3 parks at 18, and the
      # residential block's 12 = 86; supply is the 40 baseline plus the water plant's
      # health-scaled output. A water plant at 34.5333 gives 74.5333/86 = 0.86667
      # satisfaction, so the power plant's delta is -(1 - 0.86667) * 6.0 = -0.8, taking
      # 60.4 to 59.6. Waste, traffic and labour stay fully satisfied, so water is
      # genuinely its worst — the residential block is what keeps labour at 1.0, since
      # every type here but housing draws staff.
      map =
        map_with([
          %Node{Node.new(1, 0, :power_plant) | health: 60.4, status: :online},
          %Node{Node.new(0, 0, :water_plant) | health: 34.5333, status: :degraded},
          Node.new(0, 3, :park),
          Node.new(1, 3, :park),
          Node.new(2, 3, :park),
          Node.new(5, 5, :residential)
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

  describe "stalled" do
    test "a fresh city is not stalled" do
      # `Enum.all?/2` over no nodes is true, and avg_health of an empty city is 0.0 —
      # so an untouched grid satisfies the naive "everything is dead" reading. This is
      # the case the non-empty clause exists for.
      refute Calc.metrics(CityMap.new(40, 30)).stalled
    end

    test "two dead houses are not stalled — they heal from an empty treasury" do
      # 15 x 2 = 30 power against the free baseline of 40, so they are fully supplied
      # and regenerate. Consumption is not health-scaled, which is what makes the
      # count the deciding factor.
      refute Calc.metrics(dead_houses(2)).stalled
    end

    test "three dead houses are stalled" do
      # 15 x 3 = 45 against 40. The cliff is 15n <= 40.
      assert Calc.metrics(dead_houses(3)).stalled
    end

    test "three starving houses above zero health are not stalled" do
      # Starving (45 power demanded against 40) but not yet at the floor, so they are
      # still losing health rather than stuck. This is what separates `health == 0.0`
      # from a status- or threshold-based reading; without it, relaxing the clause to
      # `health < 20.0` would go unnoticed.
      refute Calc.metrics(houses(3, 10.0)).stalled
    end

    test "three dead houses plus one live one are not stalled" do
      # A uniform fixture cannot tell `Enum.all?/2` apart from `Enum.any?/2`: every node
      # in `dead_houses/1` and `houses/2` shares one health value, so both quantifiers
      # agree on every existing case above. This is the first mixed fixture in the
      # suite, and it is also the shape real gameplay produces — a partially collapsed
      # city, not a uniformly dead or uniformly healthy one.
      #
      # The extra house at full health is neither dead nor short of anything, so `all?`
      # is false here while `any?` (true as soon as the three dead houses qualify) would
      # wrongly call this city stalled — a live, still-decaying city reported as frozen.
      city = CityMap.put_node(dead_houses(3), %Node{Node.new(9, 9, :residential) | health: 100.0})
      refute Calc.metrics(city).stalled
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
        [{:power_plant, 1}, {:water_plant, 1}, {:industrial, 1}, {:transit_hub, 1}] ++
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
