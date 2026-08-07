defmodule ArmchairMetropolist.Domain.Entities.NodeTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.Node

  describe "new/3" do
    test "starts at full health and online" do
      node = Node.new(12, 7, :power_plant)
      assert node.id == "12:7"
      assert node.x == 12 and node.y == 7
      assert node.type == :power_plant
      assert node.health == 100.0
      assert node.status == :online
    end
  end

  describe "types/0" do
    test "lists all seven node types" do
      assert Enum.sort(Node.types()) ==
               Enum.sort([
                 :power_plant,
                 :water_plant,
                 :industrial,
                 :transit_hub,
                 :residential,
                 :commercial,
                 :park
               ])
    end
  end

  describe "statuses/0" do
    test "lists exactly the statuses status_for/1 can produce" do
      # Derived, not written out: snapshot_vocabulary_test.exs compares the
      # committed coverage fixture against this function, and spelling the
      # atoms here as literals would keep a retired status interned — see the
      # standing rule at the top of that file.
      produced =
        0..100
        |> Enum.map(&Node.status_for(&1 / 1))
        |> Enum.uniq()

      assert Enum.sort(Node.statuses()) == Enum.sort(produced)
    end
  end

  describe "resources/0" do
    test "lists the six resources in display order" do
      assert Node.resources() == [:power, :water, :waste, :traffic, :labour, :money]
    end
  end

  describe "negative_resources/0" do
    test "names the two resources where a rising figure is bad" do
      assert Node.negative_resources() == [:waste, :traffic]
    end

    test "every negative resource is a resource" do
      # A typo'd atom would never match anything and would simply render the old
      # sign forever, with nothing else in the suite noticing.
      assert Enum.all?(Node.negative_resources(), &(&1 in Node.resources()))
    end
  end

  describe "negative_resource?/1" do
    test "is true for the bads and false for the goods" do
      # Both halves are needed, and neither is redundant: a predicate hardcoded to
      # `true` empties `positives`, one hardcoded to `false` empties `negatives`.
      #
      # Both lists are derived from `Node.resources/0` rather than written out twice,
      # which is what actually forces the polarity decision the old literal-list
      # version only claimed to: add a seventh resource to `@resources` and it lands
      # in one of these two lists automatically, reddening `positives` (it defaults
      # into the false/positive bucket) until someone classifies it in
      # `@negative_resources`.
      negatives = Enum.filter(Node.resources(), &Node.negative_resource?/1)
      positives = Enum.reject(Node.resources(), &Node.negative_resource?/1)

      assert negatives == [:waste, :traffic]
      assert positives == [:power, :water, :labour, :money]
    end
  end

  describe "production/1 and consumption/1" do
    test "match the specified supply/demand table" do
      assert Node.production(:power_plant) == %{power: 120.0}

      assert Node.consumption(:power_plant) == %{
               water: 20.0,
               waste: 12.0,
               traffic: 3.0,
               labour: 1.0
             }

      assert Node.production(:water_plant) == %{water: 100.0}

      assert Node.consumption(:water_plant) == %{
               power: 25.0,
               waste: 6.0,
               traffic: 2.0,
               money: 5.0,
               labour: 1.0
             }

      assert Node.production(:industrial) == %{waste: 90.0}

      assert Node.consumption(:industrial) == %{
               power: 40.0,
               water: 25.0,
               traffic: 8.0,
               labour: 12.0
             }

      assert Node.production(:transit_hub) == %{traffic: 60.0}
      assert Node.consumption(:transit_hub) == %{power: 8.0, waste: 2.0, money: 4.0, labour: 2.0}

      assert Node.production(:residential) == %{labour: 5.0, money: 1.0}

      assert Node.consumption(:residential) == %{
               power: 15.0,
               water: 12.0,
               waste: 10.0,
               traffic: 6.0
             }

      assert Node.production(:commercial) == %{money: 30.0}

      assert Node.consumption(:commercial) == %{
               power: 22.0,
               water: 8.0,
               waste: 14.0,
               traffic: 9.0,
               labour: 8.0
             }

      assert Node.production(:park) == %{waste: 8.0}
      assert Node.consumption(:park) == %{water: 18.0, traffic: 2.0, money: 3.0, labour: 1.0}
    end

    # Guards the invariant SimulationCalculator's decay rule depends on:
    # worst_ratio is Enum.min over consumed resources, which raises on an
    # empty list. If a future node type consumes nothing, this fails first.
    test "every node type consumes at least one resource" do
      for type <- Node.types() do
        assert map_size(Node.consumption(type)) > 0,
               "#{type} consumes nothing, which would break worst-ratio computation"
      end
    end

    test "everything but housing is staffed, and housing supplies the staff" do
      # Positive cases first: without these, the refutation below is satisfied by a
      # consumption table that mentions labour nowhere at all.
      assert Node.consumption(:industrial)[:labour] == 12.0
      assert Node.consumption(:commercial)[:labour] == 8.0
      assert Node.consumption(:transit_hub)[:labour] == 2.0
      assert Node.consumption(:power_plant)[:labour] == 1.0
      assert Node.consumption(:water_plant)[:labour] == 1.0
      assert Node.consumption(:park)[:labour] == 1.0

      # The one exemption, and the whole reason the rule is statable.
      refute Map.has_key?(Node.consumption(:residential), :labour),
             "residential is the source of labour, not a consumer — see the park amenity spec, §3"

      # Pinned because `L` is half of the `L x k` integrality constraint the legend
      # depends on (spec §2): at L = 5 and k = 1.0 the gross bonus per park is 5.
      assert Node.production(:residential)[:labour] == 5.0
    end

    # `docs/PLAYING.md`'s "Running out of money" section tells the player that beside
    # dead blocks a house's survival "turns on those four alone", that "a shortfall in
    # labour or money cannot touch it, however severe", and that a house can therefore
    # sit at full health next to a block that never recovers. Four sentences rest on
    # this table having exactly these keys and no others: regeneration is per node over
    # `consumption/1` (`SimulationCalculator.worst_satisfaction/2` folds `min` over it),
    # so adding `labour` or `money` here makes every one of them false at once, and the
    # guide's own drift test only checks the generated blocks. Assert the key set, not
    # just the absence of labour, because `money` would break the same sentences.
    test "residential draws exactly power, water, waste and traffic" do
      assert Node.consumption(:residential) |> Map.keys() |> Enum.sort() ==
               [:power, :traffic, :waste, :water],
             "residential's consumed resources changed; docs/PLAYING.md's money section " <>
               "claims a labour or money shortfall cannot touch a house, which is only " <>
               "true while this table says so"
    end
  end

  describe "construction_cost/1 and demolition_cost/0" do
    test "match the specified construction cost table" do
      assert Node.construction_cost(:power_plant) == 80.0
      assert Node.construction_cost(:water_plant) == 70.0
      assert Node.construction_cost(:industrial) == 60.0
      assert Node.construction_cost(:transit_hub) == 40.0
      assert Node.construction_cost(:commercial) == 40.0
      assert Node.construction_cost(:park) == 20.0
      assert Node.construction_cost(:residential) == 15.0
    end

    test "every type has a construction cost" do
      # Mirrors the `Map.keys(baseline_capacity()) == Node.resources()` gate in
      # simulation_calculator_test.exs, and for the same reason: construction_cost/1 is a
      # Map.fetch!, so a type missing from the table raises at runtime instead of failing
      # a test.
      for type <- Node.types() do
        assert is_float(Node.construction_cost(type)), "#{type} has no construction cost"
      end
    end

    test "demolition is flat, and cheaper than building anything" do
      cheapest = Node.types() |> Enum.map(&Node.construction_cost/1) |> Enum.min()

      assert Node.demolition_cost() == 10.0

      assert Node.demolition_cost() < cheapest,
             "demolition (#{Node.demolition_cost()}) must stay below the cheapest " <>
               "construction cost (#{cheapest}), or tearing down becomes the expensive option"
    end

    test "every cost is a whole number" do
      # Every *display* of a cost truncates it: the legend's cost `<td>`, its
      # `cost_title/2` tooltip, and the refusal flashes `unaffordable/2` and
      # `unaffordable_demolition/1`, all in `simulator_live.ex`. A fractional cost would
      # render a figure the engine does not charge.
      #
      # "Display" and not "reader": `affordable?/2` and `ManageInfrastructure` both
      # compare the cost *raw*, and that is the point — wholeness is what makes the
      # truncated display agree with the untruncated comparison, so `trunc(money) >= cost`
      # exactly when `money >= cost`.
      for type <- Node.types() do
        cost = Node.construction_cost(type)
        assert cost == Float.round(cost), "#{type}'s cost #{cost} is not a whole number"
      end

      assert Node.demolition_cost() == Float.round(Node.demolition_cost())
    end
  end

  describe "cheapest costs" do
    test "cheapest_construction_cost is a real construction cost, and a lower bound on all of them" do
      costs = Enum.map(Node.types(), &Node.construction_cost/1)

      assert Node.cheapest_construction_cost() in costs
      assert Enum.all?(costs, &(Node.cheapest_construction_cost() <= &1))
    end

    test "cheapest_action_cost is a real action cost, and a lower bound on all of them" do
      # Characterised as "a member of the set, and <= every member" rather than by
      # restating `min(...)`. Restating the implementation's own expression would make
      # this test unable to fail.
      actions = [Node.demolition_cost() | Enum.map(Node.types(), &Node.construction_cost/1)]

      assert Node.cheapest_action_cost() in actions
      assert Enum.all?(actions, &(Node.cheapest_action_cost() <= &1))
    end

    test "today the cheapest action is the demolition fee, and the cheapest build is a house" do
      # Pins the figures the player-facing copy and the bankruptcy threshold quote.
      # The characterisations above hold for any table; these two are what change if
      # a balance patch moves the prices.
      assert Node.cheapest_action_cost() == 10.0
      assert Node.cheapest_construction_cost() == 15.0
    end
  end

  describe "status_for/1" do
    test "uses half-open intervals at the boundaries" do
      assert Node.status_for(100.0) == :online
      assert Node.status_for(60.0) == :online
      assert Node.status_for(59.9) == :degraded
      assert Node.status_for(20.0) == :degraded
      assert Node.status_for(19.9) == :offline
      assert Node.status_for(0.0) == :offline
    end
  end

  describe "display_signature/1" do
    test "is rounded health paired with status" do
      node = %Node{Node.new(1, 1, :park) | health: 87.3, status: :online}
      assert Node.display_signature(node) == {87, :online}
    end

    test "ignores sub-integer health movement" do
      # 87.6 and 87.9 both round to 88. (87.3 and 87.8 do NOT - they round to
      # 87 and 88 - so do not use those values here.)
      a = %Node{Node.new(1, 1, :park) | health: 87.6, status: :online}
      b = %Node{Node.new(1, 1, :park) | health: 87.9, status: :online}
      assert Node.display_signature(a) == Node.display_signature(b)
      assert Node.display_signature(a) == {88, :online}
    end

    test "uses round/1, not trunc/1" do
      # trunc(87.9) == 87 while round(87.9) == 88. This test exists because an
      # implementation using trunc, or snapping to the status thresholds, would
      # satisfy every other assertion here while corrupting delta membership
      # near the :degraded/:offline boundaries.
      node = %Node{Node.new(1, 1, :park) | health: 87.9, status: :online}
      assert Node.display_signature(node) == {88, :online}
    end

    test "distinguishes a status flip at identical rounded health" do
      a = %Node{Node.new(1, 1, :park) | health: 60.0, status: :online}
      b = %Node{Node.new(1, 1, :park) | health: 59.6, status: :degraded}
      assert {60, :online} = Node.display_signature(a)
      assert {60, :degraded} = Node.display_signature(b)
      refute Node.display_signature(a) == Node.display_signature(b)
    end
  end

  describe "effective_production/1" do
    test "scales production by health fraction" do
      node = %Node{Node.new(0, 0, :power_plant) | health: 50.0}
      assert effective = Node.effective_production(node)
      assert_in_delta effective.power, 60.0, 0.001
    end

    test "a near-dead plant produces almost nothing" do
      node = %Node{Node.new(0, 0, :power_plant) | health: 5.0}
      assert_in_delta Node.effective_production(node).power, 6.0, 0.001
    end

    test "commercial's money production also scales with health" do
      # Every node type produces something now (commercial produces money),
      # so there is no longer a pure-consumer example; assert the scaling
      # instead of an empty map.
      node = %Node{Node.new(0, 0, :commercial) | health: 50.0}
      assert_in_delta Node.effective_production(node).money, 15.0, 0.001
    end
  end
end
