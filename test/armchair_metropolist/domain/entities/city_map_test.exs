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

  describe "opening_grant/0" do
    test "is the money a new city starts with, from one constant" do
      # All three paths must agree. They are three because `CityEngine.normalize_city_map/1`
      # merges a decoded snapshot onto `%CityMap{}` — so the struct default is what an old
      # city inherits, while `new/2` is what a fresh one gets. Stating the figure twice
      # (as this module used to) desyncs them on a path only cold loads exercise.
      assert CityMap.opening_grant() == 400.0
      assert CityMap.new(40, 30).money == CityMap.opening_grant()
      assert %CityMap{}.money == CityMap.opening_grant()
    end
  end

  describe "debit/2" do
    test "subtracts from the treasury" do
      map = %{CityMap.new(40, 30) | money: 100.0}

      assert CityMap.debit(map, 30.0).money == 70.0
    end

    test "floors at zero rather than going negative" do
      # Unreachable through `ManageInfrastructure`, which refuses an unaffordable
      # command — the clamp documents that a balance is never negative regardless of
      # caller, which is the invariant the money design calls load-bearing.
      map = %{CityMap.new(40, 30) | money: 5.0}

      assert CityMap.debit(map, 30.0).money == 0.0
    end
  end

  describe "reset/1" do
    test "keeps the grid dimensions and discards everything else" do
      city =
        CityMap.new(12, 7)
        |> CityMap.put_node(Node.new(1, 1, :power_plant))
        |> CityMap.debit(100.0)

      city = %{city | tick: 412}

      reset = CityMap.reset(city)

      # Each property named separately: a reset that forgets one of these is a real bug
      # and a single `==` against a literal struct would not say which.
      assert reset.width == 12
      assert reset.height == 7
      assert reset.tick == 0
      assert reset.nodes == %{}
      assert reset.money == CityMap.opening_grant()
    end

    test "a reset city is indistinguishable from a new one of the same size" do
      city = CityMap.put_node(CityMap.new(40, 30), Node.new(3, 3, :commercial))

      assert CityMap.reset(city) == CityMap.new(40, 30)
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
