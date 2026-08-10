defmodule ArmchairMetropolist.Domain.Entities.CityMapTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.{CityMap, MunicipalBond, Node}

  describe "new/2" do
    test "creates an empty grid at tick zero" do
      map = CityMap.new(40, 30)
      assert map.width == 40
      assert map.height == 30
      assert map.tick == 0
      assert map.revision == 0
      assert map.nodes == %{}
      assert map.money == 0.0
      assert map.waste_stock == 0.0
      assert map.injury_stock == 0.0
      assert map.disease_stock == 0.0
      assert map.crime_stock == 0.0
      refute map.tourism_unlocked
      assert map.union_wage_level == 0
      assert map.union_strike_level == 0
      assert map.municipal_bond == nil
      assert map.commercial_bond == nil
    end
  end

  describe "tourism progression" do
    test "unlocks permanently when the fourth residential block is present" do
      below =
        Enum.reduce(0..2, CityMap.new(40, 30), fn x, map ->
          CityMap.put_node(map, Node.new(x, 0, :residential))
        end)

      refute CityMap.unlock_tourism_if_ready(below).tourism_unlocked
      refute CityMap.type_unlocked?(below, :entertainment)
      assert CityMap.type_unlocked?(below, :commercial)

      unlocked =
        below
        |> CityMap.put_node(Node.new(3, 0, :residential))
        |> CityMap.unlock_tourism_if_ready()

      assert unlocked.tourism_unlocked
      assert CityMap.type_unlocked?(unlocked, :entertainment)
      assert CityMap.type_unlocked?(unlocked, :hotel)

      reduced =
        unlocked
        |> CityMap.delete_node(0, 0)
        |> CityMap.unlock_tourism_if_ready()

      assert reduced.tourism_unlocked
      assert CityMap.residential_count(reduced) == 3
    end
  end

  describe "new/0" do
    test "starts an unissued city on the initial 4x4 grid" do
      map = CityMap.new()

      assert map.width == 4
      assert map.height == 4
      assert map.tick == 0
      assert map.revision == 0
      assert map.nodes == %{}
      assert map.money == 0.0
      assert map.municipal_bond == nil
      assert map.commercial_bond == nil
    end

    test "the struct defaults agree with new/0 on the starting grid" do
      # `CityEngine.normalize_city_map/1` merges every decoded snapshot onto a fresh
      # `%CityMap{}`, so the struct defaults are what a stored city inherits for a field
      # it lacks. A literal in `defstruct` beside a different `@initial_size` desyncs the
      # two on a path only cold loads exercise. No other test in this suite sees it.
      assert %CityMap{}.width == CityMap.new().width
      assert %CityMap{}.height == CityMap.new().height
    end
  end

  describe "grow_if_crowded/1" do
    # The threshold is pinned by three sizes, not one. Each size alone admits an interval
    # of thresholds that would pass it, and only the intersection is narrow:
    #   2x2 fires at 3, not 2  =>  t in [0.5, 0.75)     kills 0.75 and 0.8, spares 0.6
    #   4x4 fires at 12, not 11 => t in [0.6875, 0.75)  kills 0.6 (fires at 10), 0.65 (11)
    #   6x6 fires at 26, not 25 => t in [0.6944, 0.7222) kills 0.69 (fires at 25)
    # Dropping any one of these leaves a wrong constant passing.
    test "a 2x2 opens on its third block and not its second" do
      refute grown?(crowd(CityMap.new(2, 2), 2))
      assert grown?(crowd(CityMap.new(2, 2), 3))
    end

    test "a 4x4 opens on its twelfth block and not its eleventh" do
      refute grown?(crowd(CityMap.new(4, 4), 11))
      assert grown?(crowd(CityMap.new(4, 4), 12))
    end

    test "a 6x6 opens on its twenty-sixth block and not its twenty-fifth" do
      refute grown?(crowd(CityMap.new(6, 6), 25))
      assert grown?(crowd(CityMap.new(6, 6), 26))
    end

    test "growth adds two to both dimensions and opens a ring on every side" do
      grown = CityMap.grow_if_crowded(crowd(CityMap.new(2, 2), 4))

      # Both asserted: a `+1` mutant gives 3x3 and a one-axis mutant gives 4x2.
      assert grown.width == 4
      assert grown.height == 4

      # The window opens on every side, not just the right and bottom: `min_x`/`min_y`
      # both move to -1, so the new cells are as much to the left and above as they are
      # to the right and below. An anchored-growth mutant that only bumped width/height
      # would leave these at their `CityMap.new/2` default of 0.
      assert grown.min_x == -1
      assert grown.min_y == -1
    end

    test "growth leaves every node exactly where it was" do
      # The invariant this design needs, and the reason it needs no generation fence on
      # coordinate-addressed commands: a node's `x`/`y` (and therefore its id) never
      # change on growth. See spec section 9. It is the *window* that moves -- `min_x`
      # and `min_y` shift negative, tested above -- while `nodes` is untouched.
      # Comparing `nodes` by `==` catches any translation of the node map itself.
      crowded =
        Enum.reduce([{0, 0}, {1, 0}, {0, 1}, {1, 1}], CityMap.new(2, 2), fn {x, y}, map ->
          CityMap.put_node(map, Node.new(x, y, :park))
        end)

      grown = CityMap.grow_if_crowded(crowded)

      assert grown.width == 4
      assert grown.nodes == crowded.nodes
      assert Map.keys(grown.nodes) |> Enum.sort() == ["0:0", "0:1", "1:0", "1:1"]
    end

    test "growth stops at the cap" do
      # 717 nodes, not a handful: `n * 10 > 7 * 1024` needs `n >= 717`, so a sparsely
      # filled 32x32 does not grow under the correct code *or* under a cap-less mutant,
      # and a smaller fixture would pass either way.
      refute grown?(crowd(CityMap.new(32, 32), 717))
    end

    test "a city whose height alone is at the cap does not grow" do
      # 30x40 rather than the legacy 40x30 shape, deliberately. With width 40 both
      # `width < @max_size` and `max(width, height) < @max_size` are already false, so a
      # 40x30 fixture cannot separate them. Only `width < 32 <= height` makes the
      # `width`-only mutant grow where the correct predicate refuses.
      refute grown?(crowd(CityMap.new(30, 40), 841))
    end

    test "the legacy 40x30 grid does not grow" do
      # Every city stored before this change is 40x30. Asserted for its own sake: leaving
      # them alone is the point of the cap check, not a side effect of it.
      refute grown?(crowd(CityMap.new(40, 30), 841))
    end

    test "demolishing does not take rows away" do
      # A guard against a future shrink path, not a mutation kill: `grow_if_crowded/1` is
      # the only size-changing function and `delete_node/3` never calls it, so no mutation
      # of today's implementation can fail this. Do not count it as coverage.
      grown = CityMap.grow_if_crowded(crowd(CityMap.new(2, 2), 4))

      shrunk =
        Enum.reduce([{0, 0}, {1, 0}], grown, fn {x, y}, m -> CityMap.delete_node(m, x, y) end)

      assert shrunk.width == 4
      assert shrunk.height == 4
    end
  end

  # `n` distinct nodes, laid out by index across the map's own width so the fixture works
  # at every grid size this suite uses.
  defp crowd(map, n) do
    Enum.reduce(0..(n - 1), map, fn i, acc ->
      CityMap.put_node(acc, Node.new(rem(i, map.width), div(i, map.width), :park))
    end)
  end

  defp grown?(map), do: CityMap.grow_if_crowded(map) != map

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

  describe "credit/2" do
    test "adds to the treasury" do
      map = %{CityMap.new(40, 30) | money: 70.0}

      assert CityMap.credit(map, 30.0).money == 100.0
    end
  end

  describe "reset/1" do
    test "starts a new city on a fresh 4x4 grid, discarding everything else" do
      city =
        CityMap.new(12, 7)
        |> CityMap.put_node(Node.new(1, 1, :power_plant))
        |> CityMap.debit(100.0)

      city = %{
        city
        | tick: 412,
          waste_stock: 5.0,
          injury_stock: 6.0,
          disease_stock: 7.0,
          crime_stock: 8.0,
          tourism_unlocked: true
      }

      reset = CityMap.reset(city)

      # Each property named separately: a reset that forgets one of these is a real bug
      # and a single `==` against a literal struct would not say which.
      assert reset.width == 4
      assert reset.height == 4
      assert reset.tick == 0
      assert reset.revision == 0
      assert reset.nodes == %{}
      assert reset.money == 0.0
      assert reset.waste_stock == 0.0
      assert reset.injury_stock == 0.0
      assert reset.disease_stock == 0.0
      assert reset.crime_stock == 0.0
      refute reset.tourism_unlocked
      assert reset.municipal_bond == nil
      assert reset.commercial_bond == nil
    end

    test "delegates to new/0 so there is one definition of a new city" do
      city = CityMap.put_node(CityMap.new(40, 30), Node.new(3, 3, :commercial))

      # The grid does *not* survive a reset. A reset city is a new city in every respect,
      # which is what keeps `new/0` the single definition of one.
      assert CityMap.reset(city) == CityMap.new()
    end
  end

  describe "snapshot ordering" do
    test "increment_revision/1 advances revision without changing the tick" do
      map = CityMap.new() |> CityMap.increment_revision()

      assert map.tick == 0
      assert map.revision == 1
      assert CityMap.snapshot_order(map) == {0, 1}
    end

    test "legacy financing is represented as a permanent zero-balance bond" do
      bond = MunicipalBond.legacy()

      assert MunicipalBond.legacy?(bond)
      assert MunicipalBond.debt_free?(bond)
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

    test "is window-relative: a grown map accepts negative coordinates at its new origin" do
      # A map that has never grown has min_x/min_y at 0, which is what the two tests
      # above pin -- both would still pass against a mutant that used a fixed 0 lower
      # bound instead of reading `map.min_x`/`map.min_y`. This is the one that kills it:
      # after one growth the window's origin is (-1, -1), so -1 is in bounds and -2 and
      # 4 (one past the far edge, at width 4) are not.
      grown = CityMap.grow_if_crowded(crowd(CityMap.new(2, 2), 4))

      assert CityMap.in_bounds?(grown, -1, -1)
      refute CityMap.in_bounds?(grown, -2, -1)
      refute CityMap.in_bounds?(grown, -1, -2)
      refute CityMap.in_bounds?(grown, 4, -1)
      refute CityMap.in_bounds?(grown, -1, 4)
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
