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
                 :road_hub,
                 :residential,
                 :commercial,
                 :park
               ])
    end
  end

  describe "production/1 and consumption/1" do
    test "match the specified supply/demand table" do
      assert Node.production(:power_plant) == %{power: 120.0}
      assert Node.consumption(:power_plant) == %{water: 20.0, waste: 12.0, traffic: 3.0}

      assert Node.production(:water_plant) == %{water: 100.0}
      assert Node.consumption(:water_plant) == %{power: 25.0, waste: 6.0, traffic: 2.0}

      assert Node.production(:industrial) == %{waste: 90.0}
      assert Node.consumption(:industrial) == %{power: 40.0, water: 25.0, traffic: 8.0}

      assert Node.production(:road_hub) == %{traffic: 60.0}
      assert Node.consumption(:road_hub) == %{power: 8.0, waste: 2.0}

      assert Node.production(:residential) == %{}

      assert Node.consumption(:residential) == %{
               power: 15.0,
               water: 12.0,
               waste: 10.0,
               traffic: 6.0
             }

      assert Node.production(:commercial) == %{}

      assert Node.consumption(:commercial) == %{
               power: 22.0,
               water: 8.0,
               waste: 14.0,
               traffic: 9.0
             }

      assert Node.production(:park) == %{waste: 8.0}
      assert Node.consumption(:park) == %{water: 18.0, traffic: 2.0}
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
      a = %Node{Node.new(1, 1, :park) | health: 87.3, status: :online}
      b = %Node{Node.new(1, 1, :park) | health: 87.8, status: :online}
      assert Node.display_signature(a) == Node.display_signature(b)
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

    test "consumers have no production at any health" do
      node = %Node{Node.new(0, 0, :residential) | health: 100.0}
      assert Node.effective_production(node) == %{}
    end
  end
end
