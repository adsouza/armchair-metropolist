defmodule ArmchairMetropolist.Domain.Entities.CityMapTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.{CityMap, Node}

  describe "new/2" do
    test "creates an empty grid at tick zero" do
      map = CityMap.new(40, 30)
      assert map.width == 40
      assert map.height == 30
      assert map.tick == 0
      assert map.nodes == %{}
    end
  end

  describe "in_bounds?/3" do
    setup do: {:ok, map: CityMap.new(40, 30)}

    test "accepts both corners", %{map: map} do
      assert CityMap.in_bounds?(map, 0, 0)
      assert CityMap.in_bounds?(map, 39, 29)
    end

    test "rejects every off-grid direction", %{map: map} do
      refute CityMap.in_bounds?(map, -1, 0)
      refute CityMap.in_bounds?(map, 0, -1)
      refute CityMap.in_bounds?(map, 40, 0)
      refute CityMap.in_bounds?(map, 0, 30)
    end
  end

  describe "placement and removal" do
    setup do: {:ok, map: CityMap.new(40, 30)}

    test "put_node/2 stores the node under its id", %{map: map} do
      node = Node.new(3, 4, :residential)
      map = CityMap.put_node(map, node)
      assert CityMap.get_node(map, 3, 4) == node
      assert CityMap.occupied?(map, 3, 4)
    end

    test "get_node/3 returns nil for an empty cell", %{map: map} do
      assert CityMap.get_node(map, 3, 4) == nil
      refute CityMap.occupied?(map, 3, 4)
    end

    test "delete_node/3 removes only the target", %{map: map} do
      map =
        map
        |> CityMap.put_node(Node.new(3, 4, :residential))
        |> CityMap.put_node(Node.new(5, 6, :park))
        |> CityMap.delete_node(3, 4)

      refute CityMap.occupied?(map, 3, 4)
      assert CityMap.occupied?(map, 5, 6)
      assert map_size(map.nodes) == 1
    end

    test "nodes/1 lists placed nodes", %{map: map} do
      map = CityMap.put_node(map, Node.new(1, 1, :park))
      assert [%Node{type: :park}] = CityMap.nodes(map)
    end
  end
end
