defmodule ArmchairMetropolist.Domain.Services.SimulationCalculatorTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.{CityMap, MunicipalBond, Node, SimulationMetrics}
  alias ArmchairMetropolist.Domain.Services.SimulationCalculator, as: Calc

  defp map_with(nodes) do
    Enum.reduce(nodes, legacy_city(), &CityMap.put_node(&2, &1))
  end

  defp legacy_city(width \\ 40, height \\ 30) do
    %{CityMap.new(width, height) | municipal_bond: MunicipalBond.legacy(), money: 500.0}
  end

  # Helpers — added beside `map_with/1`. `map_with/1` is not reused: these need
  # per-node health and status set, and threading that through it would change a
  # helper five other fixtures depend on.
  defp houses(count, health) do
    Enum.reduce(0..(count - 1)//1, legacy_city(), fn x, map ->
      CityMap.put_node(map, %Node{
        Node.new(x, 0, :residential)
        | health: health,
          status: Node.status_for(health)
      })
    end)
  end

  defp dead_houses(count), do: %{houses(count, 0.0) | money: 0.0}

  # Two residential blocks fit inside the remaining water, waste and traffic baselines.
  # Their 30 power is imported while the treasury can pay.
  defp two_houses do
    map_with([Node.new(0, 0, :residential), Node.new(1, 0, :residential)])
  end

  # A city where water is only *slightly* short, so the resulting decay is
  # fractional and stays inside a single rounded health value.
  #
  #   power    supply 120*0.900 = 108.0        demand 25 + 15 = 40.0        -> 1.0
  #   water    supply 30 + 100*0.517 =  81.7   demand 20 + 3*18 + 12 = 86.0 -> 0.95
  #   waste    supply 40 + 3*8       =  64.0   demand 12 + 6 + 10 = 28.0    -> 1.0
  #   traffic  supply 30             =  30.0   demand 3 + 2 + 6 + 6 = 17.0  -> 1.0
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
  # water plant sits at 51.7 rather than 40.3: water demand is 86.0 now, and 0.95 of that
  # is 81.7 = 30 baseline + 51.7 health-scaled.
  #
  # Money is absent from the table because it is not meant to bind: demand is the water
  # plants' 5 each plus 3 per park = 19, against a supply of 1 from the residential block.
  # The fixture carries exactly 18, covering upkeep while leaving no budget to buy away
  # the water shortfall this test needs.
  #
  # The power plant consumes water/waste/traffic/labour, so its worst ratio is exactly
  # 0.95 (86.0 * 0.95 == 81.7) and its delta is -(1 - 0.95) * 6.0 = -0.30, taking it from
  # 90.0 to 89.7. round(90.0) == round(89.7) == 90 and the status stays :online, so its
  # display signature does not move.
  #
  # The water plant sits at "0:0" and the power plant at "1:0" deliberately. Maps iterate
  # in key order, so the water plant -- which regenerates from 51.7 to 52.7 this tick --
  # is processed first. An implementation that recomputed resource stats per node would
  # then hand the power plant a water supply of 82.7 (satisfaction 0.9616, health 89.77)
  # instead of 81.7.
  defp sub_rounding_city do
    %{
      map_with([
        %Node{Node.new(0, 0, :water_plant) | health: 51.7, status: :degraded},
        %Node{Node.new(1, 0, :power_plant) | health: 90.0, status: :online},
        Node.new(0, 3, :park),
        Node.new(1, 3, :park),
        Node.new(2, 3, :park),
        Node.new(5, 5, :residential)
      ])
      | money: 18.0
    }
  end

  describe "baseline_capacity/0" do
    test "supplies only the three free baseline resources" do
      assert Calc.baseline_capacity() == %{
               power: 0.0,
               water: 30.0,
               waste: 40.0,
               traffic: 30.0,
               injuries: 0.0,
               disease: 0.0,
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
    test "power, water, traffic and labour carry nothing" do
      stats = Calc.resource_stats(two_houses())
      # Asserted explicitly so that folding the balance back into `supplied` later
      # cannot pass silently. Waste is excluded from this list — it is in
      # `@carryover` now, alongside money, and gets its own assertion below,
      # because `two_houses/0` has `waste_stock == 0.0` and `-0.0 == 0.0`,
      # which would let this loop pass for waste whether or not it still carries.
      for resource <- [:power, :water, :traffic, :labour] do
        assert Map.fetch!(stats, resource).carried == 0.0
      end
    end

    test "waste carries its stock forward, negated" do
      # The companion to the assertion above: a nonzero stock is what makes this
      # able to fail. `carried_balance/2` returns `-city_map.waste_stock`, so a
      # mutation that dropped waste back out of `@carryover`, or one that carried
      # it unnegated, would both show up here.
      stats = Calc.resource_stats(%{two_houses() | waste_stock: 42.0})
      assert stats.waste.carried == -42.0
    end

    test "satisfaction is capped at 1.0 on surplus" do
      stats = Calc.resource_stats(two_houses())
      assert stats.water.satisfaction == 1.0
      assert stats.water.deficit == 0.0
    end

    test "satisfaction is the ratio on shortfall, and deficit is the gap" do
      # Four residential: power demand 60 with no free supply or treasury.
      map = %{map_with(for x <- 0..3, do: Node.new(x, 0, :residential)) | money: 0.0}
      stats = Calc.resource_stats(map)
      assert stats.power.supplied == 0.0
      assert_in_delta stats.power.demanded, 60.0, 0.001
      assert_in_delta stats.power.deficit, 60.0, 0.001
      assert stats.power.satisfaction == 0.0
    end

    test "satisfaction is 1.0 when nothing demands the resource" do
      stats = Calc.resource_stats(CityMap.new(40, 30))
      assert stats.power.satisfaction == 1.0
      assert stats.power.demanded == 0.0
    end

    test "includes baseline capacity in supply" do
      stats = Calc.resource_stats(CityMap.new(40, 30))
      assert_in_delta stats.water.supplied, 30.0, 0.001
    end

    test "a node's capacity scales with health but load does not" do
      # This asymmetry is the mechanism behind cascading failure. If
      # load also scaled, the simulation would silently self-stabilise
      # and the cascade test below would pass for the wrong reason.
      healthy = map_with([%Node{Node.new(0, 0, :power_plant) | health: 100.0}])
      broken = map_with([%Node{Node.new(0, 0, :power_plant) | health: 50.0}])

      assert_in_delta Calc.resource_stats(healthy).power.supplied, 120.0, 0.001
      assert_in_delta Calc.resource_stats(broken).power.supplied, 60.0, 0.001

      # A power plant consumes water 20 regardless of its own condition.
      assert_in_delta Calc.resource_stats(healthy).water.demanded, 20.0, 0.001
      assert_in_delta Calc.resource_stats(broken).water.demanded, 20.0, 0.001
    end

    # The housing requirement, stated directly rather than inferred from the tables.
    # An industrial block with nobody to staff it is the city shape this resource
    # exists to forbid.
    test "industry with no housing has no labour and decays at the full rate" do
      map = %{map_with([Node.new(0, 0, :industrial)]) | money: 0.0}
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
      # 4 residential supply 20 labour against a demand of 17: the industrial block's
      # 12, plus 1 for the water plant, 2 for the power plants and 2 for transit. The
      # margin is deliberate slack — there is no residential count that makes this exact,
      # because housing comes in units of 5.
      #
      # A bare industrial block plus 4 residential also draws more power and
      # water than baseline alone covers (industrial 40 + 4*15 = 100 power vs.
      # no free power; industrial 25 + 4*12 = 73 water vs. 40 baseline) --
      # unrelated to labour, but enough to starve and decay the block anyway.
      # Two power plants and a water plant close those gaps; transit closes the lower
      # traffic baseline, so labour is the only thing this fixture is testing.
      map =
        map_with([
          Node.new(0, 0, :industrial),
          Node.new(0, 2, :power_plant),
          Node.new(1, 2, :water_plant),
          Node.new(2, 2, :power_plant),
          Node.new(3, 2, :transit_hub)
          | for(x <- 1..4, do: Node.new(x, 0, :residential))
        ])

      stats = Calc.resource_stats(map)

      # Pinning demanded, not just satisfaction, matters: satisfaction/2 treats
      # zero demand as automatically satisfied, so a mutated industrial labour
      # demand of 0.0 would still report satisfaction 1.0 here unless demanded
      # is checked directly.
      assert stats.labour.demanded == 17.0
      assert stats.labour.supplied == 20.0
      assert stats.labour.satisfaction == 1.0

      {advanced, _delta} = Calc.advance_tick(map)
      assert CityMap.get_node(advanced, 0, 0).health == 100.0
    end

    # Finding 1's fix: the legend's totals cell reads `flow_satisfaction`, not
    # `satisfaction`, precisely so a treasury covering a deficit cannot make the
    # cell's two halves (demanded/supplied) contradict its own percentage.
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
      # Four residential: power demand 60 with no free supply, so power is genuinely
      # short. Every flow resource carries 0.0, so the two figures have
      # no basis on which to differ.
      map = %{map_with(for x <- 0..3, do: Node.new(x, 0, :residential)) | money: 0.0}
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

    test "a power plant charges recurring money upkeep" do
      city = %{
        map_with([Node.new(0, 0, :power_plant), Node.new(1, 0, :residential)])
        | money: 10.0
      }

      assert Calc.resource_stats(city).money.demanded == 5.0

      {next, _delta} = Calc.advance_tick(city)
      # The two-block city also buys the two water above the new baseline.
      assert next.money == 4.0
    end

    test "the market covers power, water, waste disposal and labour, but not traffic" do
      city = %{
        map_with(for(x <- 0..9, do: Node.new(x, 0, :commercial)))
        | money: 1_000.0
      }

      stats = Calc.resource_stats(city)

      assert Calc.market_prices() == %{power: 1.0, water: 1.0, waste: 1.0, labour: 1.0}
      assert Calc.imported_labour_traffic_per_unit() == 1.0
      assert stats.power.purchased == 220.0
      assert stats.water.purchased == 50.0
      assert stats.waste.purchased == 100.0
      assert stats.labour.purchased == 80.0
      assert stats.traffic.purchased == 0.0

      for resource <- [:power, :water, :waste, :labour] do
        assert Map.fetch!(stats, resource).deficit == 0.0
        assert Map.fetch!(stats, resource).satisfaction == 1.0
      end

      # The 80 imported workers add 80 commuter trips to the blocks' own 90 traffic.
      assert stats.traffic.demanded == 170.0
      assert stats.traffic.deficit == 140.0
      assert_in_delta stats.traffic.satisfaction, 30.0 / 170.0, 0.001
      assert Calc.metrics(city).market_spend == 450.0

      {next, _delta} = Calc.advance_tick(city)
      assert next.money == 850.0
      assert next.waste_stock == 0.0
    end

    test "an insufficient treasury funds the same fraction of every eligible shortage" do
      city = %{
        map_with(for(x <- 0..9, do: Node.new(x, 0, :commercial)))
        | money: 200.0
      }

      stats = Calc.resource_stats(city)

      # The four shortages cost 450 in total, so a treasury of 200 buys 4/9 of each.
      assert_in_delta stats.power.purchased, 880.0 / 9.0, 0.001
      assert_in_delta stats.water.purchased, 200.0 / 9.0, 0.001
      assert_in_delta stats.waste.purchased, 400.0 / 9.0, 0.001
      assert_in_delta stats.labour.purchased, 320.0 / 9.0, 0.001
      assert_in_delta stats.power.deficit, 1_100.0 / 9.0, 0.001
      assert_in_delta stats.water.deficit, 250.0 / 9.0, 0.001
      assert_in_delta stats.waste.deficit, 500.0 / 9.0, 0.001
      assert_in_delta stats.labour.deficit, 400.0 / 9.0, 0.001
      assert_in_delta stats.traffic.demanded, 90.0 + 320.0 / 9.0, 0.001
    end

    test "only labour actually purchased adds commuter traffic" do
      plant = map_with([Node.new(0, 0, :power_plant)])

      funded = Calc.resource_stats(%{plant | money: 10.0})
      assert funded.labour.purchased == 1.0
      assert funded.traffic.demanded == 4.0

      unfunded = Calc.resource_stats(%{plant | money: 0.0})
      assert unfunded.labour.purchased == 0.0
      assert unfunded.traffic.demanded == 3.0
    end

    test "net upkeep is reserved before the treasury buys a shortage" do
      city = %{map_with([Node.new(0, 0, :park)]) | money: 10.0}
      stats = Calc.resource_stats(city)

      assert stats.money.demanded == 3.0
      assert stats.labour.purchased == 1.0

      {next, _delta} = Calc.advance_tick(city)
      assert next.money == 6.0
    end

    test "current-tick income reaches the treasury before it can fund imports" do
      city = %{map_with(for(x <- 0..3, do: Node.new(x, 0, :residential))) | money: 0.0}

      stats = Calc.resource_stats(city)
      assert stats.power.deficit == 60.0
      assert stats.power.purchased == 0.0

      {next, _delta} = Calc.advance_tick(city)
      assert next.money == 4.0
      assert_in_delta Calc.metrics(next).market_spend, 4.0, 0.001
    end
  end

  describe "injuries, disease and hospitals" do
    test "traffic lowers its healthy threshold from one hundred to eighty percent" do
      safe = map_with(for(x <- 0..1, do: Node.new(x, 0, :residential)))
      busy = map_with(for(x <- 0..4, do: Node.new(x, 0, :residential)))

      assert Calc.initial_healthy_traffic_ratio() == 1.0
      assert Calc.minimum_healthy_traffic_ratio() == 0.8
      assert_in_delta Calc.healthy_traffic_ratio(0.0, 30.0), 1.0, 0.001
      assert_in_delta Calc.healthy_traffic_ratio(15.0, 30.0), 0.9, 0.001
      assert_in_delta Calc.healthy_traffic_ratio(30.0, 30.0), 0.8, 0.001
      assert_in_delta Calc.healthy_traffic_ratio(45.0, 30.0), 0.8, 0.001
      assert Calc.resource_stats(safe).injuries.demanded == 0.0

      busy_stats = Calc.resource_stats(busy)
      assert busy_stats.traffic.supplied == 30.0
      assert busy_stats.traffic.demanded == 30.0
      assert_in_delta busy_stats.injuries.demanded, 0.6, 0.001

      {next, _delta} = Calc.advance_tick(busy)
      assert_in_delta next.injury_stock, 0.6, 0.001
    end

    test "injuries and disease combine to reduce residential labour" do
      city =
        %{
          map_with([Node.new(0, 0, :residential), Node.new(1, 0, :residential)])
          | injury_stock: 6.0,
            disease_stock: 4.0
        }

      stats = Calc.resource_stats(city)
      metrics = Calc.metrics(city)

      assert_in_delta metrics.health_labour_multiplier, 0.5, 0.001
      assert_in_delta stats.labour.supplied, 5.0, 0.001
      assert_in_delta metrics.by_type.residential.actual_capacity.labour, 5.0, 0.001
    end

    test "disease outbreaks become more frequent as housing increases" do
      one_home = map_with([Node.new(0, 0, :residential)])
      two_homes = CityMap.put_node(one_home, Node.new(1, 0, :residential))
      seven_homes = map_with(for(x <- 0..6, do: Node.new(x, 0, :residential)))

      assert Calc.disease_outbreak_interval(0) == 49
      assert Calc.disease_outbreak_interval(1) == 49
      assert Calc.disease_outbreak_interval(2) == 46
      assert Calc.disease_outbreak_interval(7) == 31
      assert Calc.disease_outbreak_interval(13) == 13
      assert Calc.disease_outbreak_interval(14) == 10
      assert Calc.disease_outbreak_interval(20) == 10

      assert Calc.resource_stats(%{one_home | tick: 47}).disease.demanded == 0.0
      assert Calc.resource_stats(%{one_home | tick: 48}).disease.demanded == 2.0
      assert Calc.resource_stats(%{two_homes | tick: 44}).disease.demanded == 0.0

      outbreak_city = %{two_homes | tick: 45}
      assert Calc.resource_stats(outbreak_city).disease.demanded == 4.0
      assert Calc.resource_stats(%{seven_homes | tick: 30}).disease.demanded == 14.0

      {next, _delta} = Calc.advance_tick(outbreak_city)
      assert next.tick == 46
      assert next.disease_stock == 4.0
    end

    test "each hospital removes another ten injuries and disease cases per tick" do
      one_hospital =
        %{
          map_with([
            Node.new(0, 0, :transit_hub),
            Node.new(1, 0, :hospital)
          ])
          | injury_stock: 25.0,
            disease_stock: 25.0
        }

      two_hospitals = CityMap.put_node(one_hospital, Node.new(2, 0, :hospital))

      one = Calc.resource_stats(one_hospital)
      two = Calc.resource_stats(two_hospitals)

      assert one.injuries.deficit == 15.0
      assert one.disease.deficit == 15.0
      assert two.injuries.deficit == 5.0
      assert two.disease.deficit == 5.0

      {next, _delta} = Calc.advance_tick(two_hospitals)
      assert next.injury_stock == 5.0
      assert next.disease_stock == 5.0
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
      {map, _} = Calc.advance_tick(legacy_city())
      assert map.tick == 1
    end

    test "a small city buys the power no baseline supplies" do
      city = two_houses()
      assert Calc.resource_stats(city).power.purchased == 30.0

      {advanced, _delta} = Calc.advance_tick(city)
      assert advanced.money == 500.0 + 2.0 - 30.0
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
      # One commercial (+30) and one park (-3), starting from a known balance. With no
      # housing, the market buys 22 power and 9 labour this tick.
      map = %{map_with([Node.new(0, 0, :commercial), Node.new(1, 0, :park)]) | money: 100.0}
      {advanced, _delta} = Calc.advance_tick(map)
      assert_in_delta advanced.money, 96.0, 0.001
    end

    test "regenerates by 1.0 when fully supplied" do
      map = map_with([%Node{Node.new(0, 0, :residential) | health: 50.0, status: :degraded}])
      {map, _} = Calc.advance_tick(map)
      assert_in_delta CityMap.get_node(map, 0, 0).health, 51.0, 0.001
    end

    test "decays at the full rate when unfunded power has no baseline" do
      map = %{map_with(for x <- 0..3, do: Node.new(x, 0, :residential)) | money: 0.0}
      {map, _} = Calc.advance_tick(map)
      assert_in_delta CityMap.get_node(map, 0, 0).health, 94.0, 0.01
    end

    test "clamps at 100.0 and never exceeds it" do
      map = two_houses()
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
      # Add water and traffic capacity so only power is short. The second water plant is
      # needed now that the baseline is 30; the treasury covers its additional upkeep.
      supply = [
        Node.new(0, 5, :water_plant),
        Node.new(1, 5, :water_plant),
        Node.new(2, 5, :transit_hub)
      ]

      map = %{map_with([park | power_hogs] ++ supply) | money: 7.0}

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
        %Node{Node.new(0, 0, :water_plant) | health: 51.7, status: :degraded},
        %Node{Node.new(1, 0, :power_plant) | health: 90.0, status: :online},
        Node.new(0, 3, :park),
        Node.new(1, 3, :park),
        Node.new(2, 3, :park),
        Node.new(5, 5, :residential)
      ]

      {forward, _} = Calc.advance_tick(%{map_with(nodes) | money: 18.0})
      {reverse, _} = Calc.advance_tick(%{map_with(Enum.reverse(nodes)) | money: 18.0})
      assert forward.nodes == reverse.nodes

      # And the figures must come from the *pre-tick* map. The water plant is
      # iterated before the power plant and regenerates 51.7 -> 52.7 on this
      # tick. Recomputing stats per node would give the power plant water
      # supply 82.7 (satisfaction 0.9616, delta -0.230, health 89.77) rather
      # than the pre-tick 81.7 (satisfaction 0.95, delta -0.30, health 89.7).
      assert_in_delta CityMap.get_node(forward, 0, 0).health, 52.7, 0.001
      assert_in_delta CityMap.get_node(forward, 1, 0).health, 89.7, 0.001
    end

    test "cascading failure: a failing plant drags the city down with it" do
      # One damaged power plant supporting a large consumer load.
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
      {_map, delta} = Calc.advance_tick(two_houses())
      assert delta == %{}
    end

    test "a starved city emits only the starved nodes" do
      starving = for x <- 0..3, do: Node.new(x, 0, :residential)
      # A park is insulated from the power shortage and should stay out. Transit keeps
      # traffic supplied under the lower baseline; the treasury exactly covers upkeep.
      map = %{
        map_with([
          Node.new(0, 9, :park),
          Node.new(1, 9, :water_plant),
          Node.new(2, 9, :transit_hub)
          | starving
        ])
        | money: 8.0
      }

      {_map, delta} = Calc.advance_tick(map)

      assert Map.has_key?(delta, "0:0")
      refute Map.has_key?(delta, "0:9"), "the park does not consume power and should not change"
    end

    test "excludes a node whose health moves within the same rounded value" do
      # THE critical test: a health change too small to alter the rounded
      # display value must not enter the delta. A naive struct comparison
      # would include it and emit a full-grid delta every tick.
      #
      # Assert the display-signature property directly, then exercise it through a
      # genuine sub-rounding tick below.
      # display_signature/1, which is what the delta membership rule uses.
      a = %Node{Node.new(0, 0, :residential) | health: 87.6, status: :online}
      b = %Node{a | health: 87.9}

      assert Node.display_signature(a) == Node.display_signature(b),
             "round(87.6) == round(87.9) == 88, so this movement must not enter the delta"

      # And prove the rule is actually what advance_tick/1 applies: a city
      # already clamped at 100.0 with full supply changes no signature.
      {_map, delta} = Calc.advance_tick(two_houses())
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

      # The water plant crosses a rounding boundary (51.7 -> 52.7) in the same
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
      # residential block's 12 = 86; supply is the 30 baseline plus the water plant's
      # health-scaled output. A water plant at 44.5333 gives 74.5333/86 = 0.86667
      # satisfaction, so the power plant's delta is -(1 - 0.86667) * 6.0 = -0.8, taking
      # 60.4 to 59.6. Waste, traffic and labour stay fully satisfied, so water is
      # genuinely its worst — the residential block is what keeps labour at 1.0, since
      # every type here but housing draws staff.
      map = %{
        map_with([
          %Node{Node.new(1, 0, :power_plant) | health: 60.4, status: :online},
          %Node{Node.new(0, 0, :water_plant) | health: 44.5333, status: :degraded},
          Node.new(0, 3, :park),
          Node.new(1, 3, :park),
          Node.new(2, 3, :park),
          Node.new(5, 5, :residential)
        ])
        | money: 18.0
      }

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
      city = two_houses()
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

    test "funded dead houses are not stalled because they can import power" do
      city = %{dead_houses(2) | money: 30.0}
      refute Calc.metrics(city).stalled

      {next, _delta} = Calc.advance_tick(city)
      assert next.nodes["0:0"].health == 1.0
    end

    test "an unfunded dead city is stalled with no free power" do
      assert Calc.metrics(dead_houses(3)).stalled
    end

    test "three starving houses above zero health are not stalled" do
      # Starving on power but not yet at the floor, so they are
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

  describe "insolvency" do
    test "money_ceiling is the rated sum, not the health-scaled one" do
      # One house at 20% health beside a full-health shop. Rated: 1 + 30 = 31. Scaled:
      # 0.2 + 30 = 30.2. A fixture at full health cannot tell those apart, which is the
      # whole distinction this field exists to make.
      city =
        map_with([
          %Node{Node.new(0, 0, :residential) | health: 20.0, status: :degraded},
          Node.new(1, 0, :commercial)
        ])

      assert Calc.metrics(city).money_ceiling == 31.0
    end

    test "a house beside a park is insolvent — upkeep 3 against a ceiling of 1" do
      assert Calc.metrics(map_with([Node.new(0, 0, :residential), Node.new(1, 0, :park)])).insolvent
    end

    test "a lone house is solvent — it has upkeep of nothing" do
      # Kills a gate that reads bare bankruptcy: this city at an empty treasury earns
      # 1/tick against no upkeep and is over the line in ten ticks.
      refute Calc.metrics(map_with([Node.new(0, 0, :residential)])).insolvent
    end

    test "a city whose shop is merely sick is solvent, though it is draining today" do
      # THE mutation this block exists to catch: comparing `supplied` against `demanded`
      # instead of the rated ceiling. Measured, this city's money flow is 2.5 against 3
      # of upkeep, so a flow-based gate condemns it — and it recovers to 9832 within 400
      # ticks, because the shop heals to a rated 30.
      city =
        map_with([
          Node.new(0, 0, :residential),
          %Node{Node.new(1, 0, :commercial) | health: 5.0, status: :offline},
          Node.new(2, 0, :park)
        ])

      metrics = Calc.metrics(%{city | money: 0.0})

      assert metrics.resources.money.supplied < metrics.resources.money.demanded
      refute metrics.insolvent
    end

    test "an empty grid is solvent — no upkeep and no income" do
      # `0.0 < 0.0` is false, so this needs no special casing; the test pins that it
      # stays that way. An empty grid already has its own Reset affordance via
      # `node_count`/`bankrupt`, and calling it insolvent would put a "City locked"
      # banner on a fresh city.
      refute Calc.metrics(CityMap.new(40, 30)).insolvent
    end

    test "quotes the commercial shortfall plus six projected ticks for a healthy city" do
      city =
        map_with([
          Node.new(0, 0, :residential),
          Node.new(1, 0, :power_plant),
          Node.new(2, 0, :water_plant)
        ])
        |> Map.put(:money, 0.0)

      assert Calc.metrics(city).commercial_bond_offer == %{
               principal: 94.0,
               construction_cost: 40.0,
               runway_ticks: 6
             }
    end

    test "includes existing opening-bond service in the six-tick bridge quote" do
      {:ok, bond} = MunicipalBond.new(400.0)

      city =
        %{
          CityMap.new(40, 30)
          | municipal_bond: MunicipalBond.start(bond, 0),
            tick: 20
        }
        |> CityMap.put_node(Node.new(0, 0, :residential))
        |> CityMap.put_node(Node.new(1, 0, :power_plant))
        |> CityMap.put_node(Node.new(2, 0, :water_plant))

      assert Calc.metrics(city).commercial_bond_offer == %{
               principal: 130.0,
               construction_cost: 40.0,
               runway_ticks: 6
             }
    end

    test "does not offer the bridge when the city is damaged or can still afford commerce" do
      city =
        map_with([
          Node.new(0, 0, :residential),
          Node.new(1, 0, :power_plant),
          Node.new(2, 0, :water_plant)
        ])

      refute Calc.metrics(%{city | money: 40.0}).commercial_bond_offer

      damaged =
        CityMap.put_node(
          %{city | money: 0.0},
          %Node{Node.new(0, 0, :residential) | health: 99.0, status: :online}
        )

      refute Calc.metrics(damaged).commercial_bond_offer
    end

    test "does not offer the bridge or lock the city during opening planning" do
      {:ok, bond} = MunicipalBond.new(400.0)

      city =
        map_with([
          Node.new(0, 0, :residential),
          Node.new(1, 0, :power_plant),
          Node.new(2, 0, :water_plant)
        ])
        |> Map.merge(%{money: 0.0, municipal_bond: bond})

      metrics = Calc.metrics(city)

      refute metrics.commercial_bond_offer
      refute SimulationMetrics.game_over?(metrics)
    end
  end

  describe "escape" do
    test "nil on a solvent city — there is nothing to escape" do
      refute Calc.metrics(map_with([Node.new(0, 0, :residential)])).escape
    end

    test "prefers a demolition when one alone closes the gap" do
      # Gap 2: upkeep 3 (one park) against a ceiling of 1 (one house). Demolishing the
      # park removes 3 of upkeep, which covers 2, and costs 10 — cheaper than the 40 shop
      # that would also cover it. Kills returning the first candidate found, and kills
      # returning `cheapest_action_cost` unconditionally, since that would name no type.
      city = map_with([Node.new(0, 0, :residential), Node.new(1, 0, :park)])

      assert Calc.metrics(city).escape == {:demolish, :park, 10.0}
    end

    test "names the shop when no single demolition closes the gap" do
      # Gap 7: a water plant's 5 and a park's 3 against a ceiling of 1. Neither single
      # demolition covers 7 — 5 < 7 and 3 < 7 — so the cheapest sufficient action is the
      # shop's +30 at 40. Asymmetric upkeep on purpose: with two parks the two candidate
      # demolitions would be indistinguishable and the test could not tell "no single
      # demolition is enough" from "demolitions are not considered".
      city =
        map_with([
          Node.new(0, 0, :residential),
          Node.new(1, 0, :water_plant),
          Node.new(2, 0, :park)
        ])

      assert Calc.metrics(city).escape == {:place, :commercial, 40.0}
    end

    test "will not name a placement it cannot make on a full grid" do
      # `ManageInfrastructure.place/4` refuses every occupied coordinate, so on a full grid
      # a priced placement is an instruction the player cannot follow.
      #
      # The fixture has to be chosen with care, because demolition at 10 is strictly
      # cheaper than the cheapest construction at 15 — pinned by `node_test.exs` — so a
      # placement can never *outbid* a demolition. The free-cell filter therefore only
      # changes the answer where no single demolition qualifies and a placement does.
      #
      # Gap 7: one house's ceiling of 1 against a water plant's 5 and a park's 3. No single
      # demolition covers 7 (5 < 7, 3 < 7), while the shop's +30 does. On an open grid this
      # city answers `{:place, :commercial, 40.0}`; full, the honest answer is that no one
      # action will do it.
      city = full_grid_gap_of_seven()

      assert length(CityMap.nodes(city)) == 40 * 30
      assert Calc.metrics(city).escape == {:multiple, 10.0}
    end

    test "names the shop for that same city once a single cell is free" do
      # The other half of the pair: identical but for one demolished cell, so the only
      # thing that can explain the difference is the free-cell test. Without it both
      # cities answer `{:place, :commercial, 40.0}` and the test above is the only one
      # that fails — with it, this one pins that the filter has not been made
      # unconditional.
      city = CityMap.delete_node(full_grid_gap_of_seven(), 39, 29)

      assert length(CityMap.nodes(city)) == 40 * 30 - 1
      assert Calc.metrics(city).escape == {:place, :commercial, 40.0}
    end

    test "reports :multiple when no single action closes the gap" do
      # Eleven parks are 33 of upkeep against a ceiling of 1: the shop's +30 is not
      # enough and no single park demolition's 3 is either. The copy has to say "more
      # than one block" rather than name an action that would not work.
      city = map_with([Node.new(0, 0, :residential) | for(i <- 1..11, do: Node.new(i, 0, :park))])

      assert Calc.metrics(city).escape == {:multiple, 10.0}
    end
  end

  describe "rescue_window" do
    test "nil on a solvent city" do
      refute Calc.metrics(map_with([Node.new(0, 0, :residential)])).rescue_window
    end

    test "counts the ticks until the escape stops being affordable" do
      # One house, one park: the treasury also imports 17 power a tick, so the escape is
      # still the park demolition at 10 but the affordable window is now only two ticks.
      #
      assert house_and_park(30.0).rescue_window == 2
    end

    test "nil beyond the horizon rather than a large number" do
      # A large enough bank keeps the 19-a-tick combined upkeep and power-import drain
      # affordable beyond the 60-tick horizon. The projection stops rather than running
      # it out.
      refute house_and_park(2_000.0).rescue_window
    end

    test "is zero once the escape is already unaffordable" do
      # Bank 9 is below the park demolition's 10, so there is no window left at all. Zero
      # and not nil: nil means "not within the horizon", which is the opposite situation,
      # and a single `nil` for both would make the banner unable to tell them apart.
      assert house_and_park(9.0).rescue_window == 0
    end

    test "survives a city whose income falls while the treasury drains" do
      # THE mutation this block exists to catch: computing the window as
      # `money / (demanded - supplied)` from the *current* drain.
      #
      # One house, one shop and eleven parks. Ceiling 31 against 33 of upkeep, so today's
      # drain is 2 — but the parks alone draw 198 water against a baseline of 30, so the shop
      # starves and its health-scaled income falls every tick. Measured, income goes
      # 31 -> 21.96 and the operating gap grows 2 -> 11.04 over five ticks.
      #
      # A division by today's drain reports (35 - 10) / 2 = 12 ticks. Automatic water
      # purchases consume the affordable escape after one tick, which the projection sees
      # and the division cannot.
      assert Calc.metrics(collapsing_income_city(35.0)).rescue_window == 1
    end

    test "nil for a stalled city, whose treasury the engine has already frozen" do
      # A single dead water plant: ceiling 0 against 5 of upkeep, so insolvent; 50 in the
      # bank, so not bankrupt; and stalled, because it is at zero health and starved of
      # labour. `CityEngine` runs no tick while stalled, so that 50 never moves and any
      # countdown in ticks describes something that will not happen.
      dead_plants =
        for x <- 0..9,
            do: %Node{Node.new(x, 0, :water_plant) | health: 0.0, status: :offline}

      city = %{map_with(dead_plants) | money: 50.0}

      metrics = Calc.metrics(city)

      assert metrics.stalled
      assert metrics.insolvent
      refute metrics.bankrupt
      refute metrics.rescue_window
    end

    test "stops projecting at the tick the city stalls" do
      # Three dead houses have no free power and hold at zero. A projection that ignored
      # the engine's tick-skip would keep draining them
      # past the freeze and report a window; the freeze is what makes the honest answer
      # nil. Their upkeep is nothing though, so to be insolvent at all this city needs a
      # park, so the fixture uses the park's own upkeep and lets the houses do the stalling.
      city = %{
        map_with([
          %Node{Node.new(0, 0, :residential) | health: 0.0, status: :offline},
          %Node{Node.new(1, 0, :residential) | health: 0.0, status: :offline},
          %Node{Node.new(2, 0, :residential) | health: 0.0, status: :offline},
          %Node{Node.new(3, 0, :park) | health: 0.0, status: :offline}
        ])
        | money: 3.0
      }

      assert Calc.metrics(city).stalled
      refute Calc.metrics(city).rescue_window
    end
  end

  describe "waste as an accumulating stock" do
    test "unprocessed waste carries into the next tick" do
      city = five_houses()
      assert city.waste_stock == 0.0

      {next, _delta} = Calc.advance_tick(city)

      # 50 emitted, 40 absorbed by the baseline, 10 left in the ground.
      assert_in_delta next.waste_stock, 10.0, 0.001
    end

    test "the stock drains on spare capacity and reaches exactly zero" do
      # Five houses (50 emitted) plus one industrial (90 capacity) against the
      # baseline's 40: capacity 130, emissions 50, so the first tick's drain is
      # exactly 200 + 50 - 130 = 120 — every node is still at full health here,
      # so this is the clean statement of the drain rate.
      nodes = [Node.new(9, 9, :industrial) | for(i <- 0..4, do: Node.new(i, 0, :residential))]
      city = %{map_with(nodes) | waste_stock: 200.0, money: 0.0}

      {t1, _} = Calc.advance_tick(city)
      {t2, _} = Calc.advance_tick(t1)
      {t3, _} = Calc.advance_tick(t2)

      assert_in_delta t1.waste_stock, 120.0, 0.001

      # t2 is asserted as "smaller", not as a figure: this fixture's industrial
      # block has no power or water behind it, so it decays from tick 2 onward
      # and its health-scaled capacity shrinks with it. Measured, t2 is 1001/23
      # (~43.52) rather than the 40.0 a constant-capacity city would give. The
      # drain rate is stated exactly at t1, where every node is still at full
      # health, and the destination is stated exactly at t3.
      assert t2.waste_stock < t1.waste_stock

      # Exactly zero, not merely smaller: a stock that decreases without ever
      # clearing is a different and much crueller mechanic.
      assert t3.waste_stock == 0.0
    end

    test "a backlog worsens satisfaction instead of improving it" do
      # THE mutation this whole describe block exists to catch: `carried(:waste)`
      # returning +stock rather than -stock turns the landfill into a second
      # treasury. Every "the city survives" test in the suite passes under it.
      clean = five_houses()
      backlogged = %{five_houses() | waste_stock: 60.0}

      clean_sat = Calc.resource_stats(clean).waste.satisfaction
      backlogged_sat = Calc.resource_stats(backlogged).waste.satisfaction

      # 40/50 = 0.8 clean; (40 - 60)/50 = -0.4 backlogged. Under the sign mutation
      # the backlogged figure becomes min(1.0, 100/50) = 1.0 and this fails.
      assert_in_delta clean_sat, 0.8, 0.001
      assert_in_delta backlogged_sat, -0.4, 0.001
      assert clean_sat > backlogged_sat
    end

    test "the backlog does not touch flow_satisfaction" do
      # `flow_satisfaction` answers "is my per-tick economy balanced", which stays
      # true while digging out. Catches the mutation that wires the stock into it.
      clean = Calc.resource_stats(five_houses()).waste.flow_satisfaction

      backlogged =
        Calc.resource_stats(%{five_houses() | waste_stock: 60.0}).waste.flow_satisfaction

      assert_in_delta clean, 0.8, 0.001
      assert_in_delta backlogged, 0.8, 0.001
    end

    test "traffic does not accumulate" do
      # Only waste is in @carryover. Six houses draw 36 traffic against the
      # baseline's 40 and 60 waste against the same 40, so waste builds a stock
      # in the very same tick that traffic does not.
      city = %{map_with(for(i <- 0..5, do: Node.new(i, 0, :residential))) | money: 0.0}
      {next, _} = Calc.advance_tick(city)

      assert_in_delta next.waste_stock, 20.0, 0.001

      # A forward tripwire, not the catch: `%CityMap{}` has no `:traffic_stock`
      # key today and never has, so this cannot fail on its own. What actually
      # catches `:traffic` being added to `@carryover` is the `carried == 0.0`
      # assertion below.
      refute Map.has_key?(next, :traffic_stock)
      assert Calc.resource_stats(next).traffic.carried == 0.0
    end

    test "a large backlog decays health faster than @decay_per_tick" do
      # The consequence of leaving satisfaction unfloored, asserted directly so
      # that adding a `max(0.0, ...)` later reddens something.
      #
      # Five houses at 200 stock: waste demanded 50, supplied 40, available -160,
      # satisfaction -3.2. Power is the next worst at 40/75 = 0.533, so waste is
      # the binding constraint. health_delta = -(1 - -3.2) * 6.0 = -25.2.
      city = %{five_houses() | waste_stock: 200.0}
      {next, _} = Calc.advance_tick(city)

      assert_in_delta next.nodes["0:0"].health, 74.8, 0.001

      # And the contrast, so the figure above cannot be satisfied by a coincidence:
      # the same unfunded city with no backlog loses 6.0 on its zero power satisfaction.
      {clean_next, _} = Calc.advance_tick(five_houses())
      assert_in_delta clean_next.nodes["0:0"].health, 94.0, 0.001
    end

    test "a city whose landfill is still draining is not stalled" do
      # Five dead houses emit 50 against the baseline's 40, so at stock 60 the
      # next deficit is max(0, 50 - 40 + 60) = 70 — still climbing, no route back.
      dead = for i <- 0..4, do: %Node{Node.new(i, 0, :residential) | health: 0.0}
      assert Calc.metrics(%{map_with(dead) | waste_stock: 60.0, money: 0.0}).stalled

      # Two dead houses, not an empty grid: `stalled?([], _, _)` short-circuits to
      # false before the stock conjunct is reached, so an empty city cannot
      # observe this clause at all. These two emit 20 against the baseline's 40,
      # so at stock 60 the next deficit is 40 — draining, and therefore not
      # stalled. The engine skips ticks while stalled, so calling this stalled
      # would freeze the landfill permanently.
      dead = for i <- 0..1, do: %Node{Node.new(i, 0, :residential) | health: 0.0}
      refute Calc.metrics(%{map_with(dead) | waste_stock: 60.0, money: 0.0}).stalled
    end

    test "a settled dead city is still stalled" do
      # The regression guard for the clause above: three dead houses emit 30
      # against the baseline's 40, so the deficit is 0, equal to the stock, and
      # nothing is moving. Unfunded power is what keeps them dead.
      dead = for i <- 0..2, do: %Node{Node.new(i, 0, :residential) | health: 0.0}

      assert Calc.metrics(%{map_with(dead) | money: 0.0}).stalled
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

  describe "municipal bond accounting" do
    test "pays upkeep before debt and records the unpaid balance as arrears" do
      city =
        active_bond_city(400.0, 20, 6.0)
        |> CityMap.put_node(Node.new(0, 0, :water_plant))

      {next, _delta} = Calc.advance_tick(city)

      assert next.money == 0.0
      assert next.municipal_bond.outstanding_principal == 400.0
      assert next.municipal_bond.interest_arrears == 1.0
      assert next.municipal_bond.principal_arrears == 4.0
    end

    test "pays debt before imports while current income remains eligible for debt service" do
      city =
        active_bond_city(400.0, 20, 19.0)
        |> CityMap.put_node(Node.new(0, 0, :residential))

      metrics = Calc.metrics(city)
      {next, _delta} = Calc.advance_tick(city)

      assert metrics.resources.money.demanded == 0.0
      assert metrics.resources.power.purchased == 14.0
      assert metrics.resources.power.deficit == 1.0
      assert next.municipal_bond.outstanding_principal == 396.0
      assert next.municipal_bond.interest_arrears == 0.0
      assert next.money == 0.0
      assert CityMap.get_node(next, 0, 0).health < 100.0
    end

    test "bond service is not attributed to the money resource or a type row" do
      city =
        active_bond_city(400.0, 20, 100.0)
        |> CityMap.put_node(Node.new(0, 0, :water_plant))

      metrics = Calc.metrics(city)

      assert metrics.resources.money.demanded == 5.0
      assert metrics.by_type.water_plant.load.money == 5.0
      assert metrics.bond.next_payment == 6.0
    end

    test "services the commercial bridge after its own opening period" do
      city = %{
        legacy_city()
        | tick: 20,
          money: 100.0,
          commercial_bond: MunicipalBond.commercial_bridge(94.0, 0)
      }

      metrics = Calc.metrics(city)
      {next, _delta} = Calc.advance_tick(city)

      assert_in_delta metrics.commercial_bond.next_payment, 1.41, 1.0e-9
      assert_in_delta metrics.treasury_delta, -1.41, 1.0e-9
      assert_in_delta next.money, 98.59, 1.0e-9
      assert_in_delta next.commercial_bond.outstanding_principal, 93.06, 1.0e-9
    end

    test "unissued and issued-unstarted clocks change neither tick nor bond" do
      unissued = CityMap.new()
      {:ok, bond} = MunicipalBond.new(400.0)
      unstarted = %{CityMap.new() | municipal_bond: bond, money: 400.0}

      assert Calc.advance_tick(unissued) == {unissued, %{}}
      assert Calc.advance_tick(unstarted) == {unstarted, %{}}
      assert Calc.metrics(unissued).treasury_delta == 0.0
      assert Calc.metrics(unstarted).treasury_delta == 0.0
    end

    test "a documented finished city clears a recoverable default" do
      {:ok, bond} = MunicipalBond.new(400.0)
      bond = MunicipalBond.start(bond, 0)
      %{bond: bond} = MunicipalBond.service(bond, 20, 0.0)

      city =
        opening_nodes()
        |> map_with()
        |> Map.merge(%{tick: 21, money: 0.0, municipal_bond: bond})

      assert MunicipalBond.defaulted?(city.municipal_bond)

      {next, _delta} = Calc.advance_tick(city)

      refute MunicipalBond.defaulted?(next.municipal_bond)
      assert next.municipal_bond.outstanding_principal < bond.outstanding_principal
    end

    test "the finance lock uses interest equality and optimistic sub-10 redemption" do
      {:ok, bond} = MunicipalBond.new(400.0)
      bond = %{MunicipalBond.start(bond, 0) | interest_arrears: 8.0}

      city =
        map_with([Node.new(0, 0, :residential), Node.new(1, 0, :residential)])
        |> Map.merge(%{tick: 40, money: 8.0, municipal_bond: bond})

      locked = Calc.metrics(city)
      assert locked.financing_locked
      assert locked.financing_escape == {:multiple, Node.cheapest_action_cost()}
      assert SimulationMetrics.game_over?(locked)

      rescued = Calc.metrics(%{city | money: 9.0})
      refute rescued.financing_locked
      refute SimulationMetrics.game_over?(rescued)
    end
  end

  # Five houses emit 50 waste against the free baseline's 40. Five and not four:
  # four emit exactly 40, leave nothing, and would make every waste-stock
  # assertion read the same whether the mechanic exists or not.
  defp five_houses,
    do: %{map_with(for(i <- 0..4, do: Node.new(i, 0, :residential))) | money: 0.0}

  defp active_bond_city(principal, tick, money) do
    {:ok, bond} = MunicipalBond.new(principal)

    %{
      CityMap.new(40, 30)
      | municipal_bond: MunicipalBond.start(bond, 0),
        tick: tick,
        money: money
    }
  end

  defp opening_nodes do
    [
      :residential,
      :power_plant,
      :transit_hub,
      :commercial,
      :water_plant,
      :residential,
      :park,
      :park
    ]
    |> Enum.with_index(fn type, x -> Node.new(x, 0, type) end)
  end

  # One house and one park: a rated ceiling of 1 against 3 of upkeep, with the park
  # demolition at 10 as the escape. Its 17 power is imported while funds last, so the
  # combined upkeep and market drain is 19 per tick.
  defp house_and_park(money) do
    Calc.metrics(%{
      map_with([Node.new(0, 0, :residential), Node.new(1, 0, :park)])
      | money: money
    })
  end

  # One house, one shop and eleven parks. The money side is nearly balanced — a rated
  # ceiling of 31 against 33 of upkeep — while the water side is not remotely: eleven parks
  # draw 198 against a baseline of 30. So the shop starves, its health-scaled income falls
  # every tick, and the drain grows. The count is eleven because that is what puts the gap
  # at 2, small enough that a division by today's drain reports a comfortable window.
  defp collapsing_income_city(money) do
    nodes =
      [Node.new(0, 0, :residential), Node.new(1, 0, :commercial)] ++
        for i <- 0..10, do: Node.new(i, 1, :park)

    %{map_with(nodes) | money: money}
  end

  # Every one of the 1,200 cells filled, with a money gap of exactly 7: one house supplying
  # a rated ceiling of 1 against a water plant's 5 and a park's 3 of upkeep.
  #
  # The 1,197 fillers are industrial because that type touches money in neither table —
  # net 0 each — so the gap is set by the three named blocks alone and stays 7 however many
  # fillers there are. That is also what makes deleting the last cell a money-neutral edit,
  # which the paired test relies on.
  #
  # 7 and not some smaller gap: it has to exceed every single type's money load (the water
  # plant's 5 is the largest) so that no lone demolition qualifies, while staying under the
  # shop's +30 so a placement does. That gap is the only shape in which the free-cell filter
  # can change the answer.
  defp full_grid_gap_of_seven do
    for y <- 0..29, x <- 0..39, reduce: legacy_city() do
      map ->
        type =
          case y * 40 + x do
            0 -> :residential
            1 -> :water_plant
            2 -> :park
            _index -> :industrial
          end

        CityMap.put_node(map, Node.new(x, y, type))
    end
  end
end
