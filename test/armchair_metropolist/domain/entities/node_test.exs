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
