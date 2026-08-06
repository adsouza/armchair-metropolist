defmodule ArmchairMetropolist.UseCases.ManageInfrastructureTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ArmchairMetropolist.Domain.Entities.{CityMap, Node}
  alias ArmchairMetropolist.UseCases.ManageInfrastructure

  setup do: {:ok, map: CityMap.new(40, 30)}

  describe "place/4" do
    test "places a healthy online node at the requested cell", %{map: map} do
      assert {:ok, {map, node}} = ManageInfrastructure.place(map, 3, 4, :power_plant)
      assert node.id == "3:4"
      assert node.health == 100.0
      assert node.status == :online
      assert CityMap.get_node(map, 3, 4) == node
    end

    test "rejects every out-of-bounds direction", %{map: map} do
      assert {:error, :out_of_bounds} = ManageInfrastructure.place(map, -1, 0, :park)
      assert {:error, :out_of_bounds} = ManageInfrastructure.place(map, 0, -1, :park)
      assert {:error, :out_of_bounds} = ManageInfrastructure.place(map, 40, 0, :park)
      assert {:error, :out_of_bounds} = ManageInfrastructure.place(map, 0, 30, :park)
    end

    test "rejects an occupied cell", %{map: map} do
      {:ok, {map, _}} = ManageInfrastructure.place(map, 3, 4, :park)
      assert {:error, :occupied} = ManageInfrastructure.place(map, 3, 4, :residential)
    end

    test "rejects an unknown node type", %{map: map} do
      assert {:error, :unknown_type} = ManageInfrastructure.place(map, 3, 4, :space_elevator)
    end

    test "checks bounds before type: out-of-bounds and unknown-type together is :out_of_bounds",
         %{map: map} do
      # Pins the guard order in place/4. Both the bounds check and the type
      # check would independently reject this call, so this is the only case
      # that can tell them apart: if a reviewer ever swaps the `cond` clauses,
      # this returns :unknown_type instead and the test catches it, where
      # every other test here (each violating only one guard) would not.
      assert {:error, :out_of_bounds} = ManageInfrastructure.place(map, 40, 0, :space_elevator)
    end

    test "leaves other nodes untouched", %{map: map} do
      {:ok, {map, first}} = ManageInfrastructure.place(map, 1, 1, :park)
      {:ok, {map, _}} = ManageInfrastructure.place(map, 2, 2, :residential)
      assert CityMap.get_node(map, 1, 1) == first
    end

    test "debits the treasury by exactly the type's cost" do
      map = %{CityMap.new(40, 30) | money: 100.0}

      {:ok, {map, _node}} = ManageInfrastructure.place(map, 1, 1, :park)

      assert map.money == 80.0
    end

    test "a balance exactly equal to the cost succeeds and leaves zero" do
      # The test that kills `<` flipped to `<=`. Built from a literal balance rather than
      # a simulated one: a damaged producer yields fractional income, and an exact
      # equality against a simulated balance would be asserting float noise.
      map = %{CityMap.new(40, 30) | money: 20.0}

      assert {:ok, {map, _node}} = ManageInfrastructure.place(map, 1, 1, :park)
      assert map.money == 0.0
    end

    test "refuses an unaffordable build" do
      # Only the error tuple, deliberately. "Changes nothing" is not assertable at this
      # layer and this test used to claim it was: a refusal returns no map, so the only
      # `CityMap` in scope is the caller's own binding, which nothing `place/4` does can
      # reach. `assert map.money == 19.0` after this call is unfalsifiable — measured, not
      # reasoned: under a debit-before-the-gate mutation it stayed green while five other
      # tests went red.
      #
      # Where the property *is* observable: "a refused command leaves the engine's balance
      # untouched" in city_engine_test.exs, where the balance lives in a process that
      # survives the call.
      map = %{CityMap.new(40, 30) | money: 19.0}

      assert {:error, :insufficient_funds} = ManageInfrastructure.place(map, 1, 1, :park)
    end

    test "reports occupancy before affordability" do
      # Clause ordering, invisible in review because every clause returns an error
      # tuple. A click on an occupied cell should not report that you are broke about a
      # build that was never possible on that cell.
      {:ok, {map, _}} = ManageInfrastructure.place(CityMap.new(40, 30), 1, 1, :park)
      broke = %{map | money: 0.0}

      assert {:error, :occupied} = ManageInfrastructure.place(broke, 1, 1, :park)
    end

    test "reports an unknown type before affordability, and does not raise" do
      # `construction_cost/1` is a `Map.fetch!`, so an unknown type reaching the cost
      # check raises KeyError inside a GenServer.call instead of returning an error
      # tuple — which takes the engine down and rolls the city back to its last
      # checkpoint. This test is the guard on that clause order.
      broke = %{CityMap.new(40, 30) | money: 0.0}

      assert {:error, :unknown_type} = ManageInfrastructure.place(broke, 1, 1, :airport)
    end

    property "place/4 either succeeds and debits exactly the cost, or fails and changes nothing" do
      check all(
              type <- StreamData.member_of(Node.types()),
              money <- StreamData.float(min: 0.0, max: 200.0)
            ) do
        map = %{CityMap.new(40, 30) | money: money}
        cost = Node.construction_cost(type)

        case ManageInfrastructure.place(map, 1, 1, type) do
          {:ok, {placed, _node}} ->
            assert placed.money == money - cost
            assert map_size(placed.nodes) == 1

          {:error, :insufficient_funds} ->
            assert money < cost
        end
      end
    end
  end

  describe "demolish/3" do
    test "removes the node and returns its id", %{map: map} do
      {:ok, {map, _}} = ManageInfrastructure.place(map, 3, 4, :park)
      assert {:ok, {map, "3:4"}} = ManageInfrastructure.demolish(map, 3, 4)
      refute CityMap.occupied?(map, 3, 4)
    end

    test "rejects a vacant cell", %{map: map} do
      assert {:error, :empty} = ManageInfrastructure.demolish(map, 3, 4)
    end

    test "removes exactly one node", %{map: map} do
      {:ok, {map, _}} = ManageInfrastructure.place(map, 1, 1, :park)
      {:ok, {map, _}} = ManageInfrastructure.place(map, 2, 2, :park)
      {:ok, {map, _}} = ManageInfrastructure.demolish(map, 1, 1)
      assert map_size(map.nodes) == 1
    end

    test "place then demolish restores the map's nodes, minus what both cost", %{map: map} do
      # No longer `restored == map`: the round trip costs 60 to build an industrial and
      # 10 to tear it down, and that 70 does not come back. Asserting on `nodes` keeps
      # the property the test was written for — teardown leaves no trace on the grid —
      # while naming the money as a separate, deliberate difference.
      {:ok, {placed, _}} = ManageInfrastructure.place(map, 5, 5, :industrial)
      {:ok, {restored, _}} = ManageInfrastructure.demolish(placed, 5, 5)

      assert restored.nodes == map.nodes
      assert restored.money == map.money - 70.0
    end

    test "debits the flat demolition cost" do
      {:ok, {map, _}} = ManageInfrastructure.place(CityMap.new(40, 30), 1, 1, :park)
      map = %{map | money: 100.0}

      {:ok, {map, _id}} = ManageInfrastructure.demolish(map, 1, 1)

      assert map.money == 90.0
    end

    test "refuses an unaffordable demolition" do
      # Same amendment as `place/4`'s refusal test above, and for the same reason. The two
      # assertions struck from here were `map.money == 9.0` and
      # `refute CityMap.get_node(map, 1, 1) == nil` — both about a binding made two lines
      # earlier, the second about a node this test put there itself, so neither could fail
      # for any implementation of `demolish/3`. The `refute` also had no positive case and
      # could not be given one, which is the shape this suite treats as a defect.
      #
      # "The node still stands" is observable in city_engine_test.exs, against an engine's
      # state rather than a local binding.
      {:ok, {map, _}} = ManageInfrastructure.place(CityMap.new(40, 30), 1, 1, :park)
      map = %{map | money: 9.0}

      assert {:error, :insufficient_funds} = ManageInfrastructure.demolish(map, 1, 1)
    end

    test "a balance exactly equal to the demolition cost succeeds and leaves zero" do
      # The demolish counterpart of `place/4`'s `<`-vs-`<=` test, which this file was
      # missing: no other fixture holds exactly 10.0 going into a demolish (the refusal
      # above uses 9.0, the debit test 100.0, the round trip 90.0), so nothing killed
      # `<` flipped to `<=` on this gate.
      {:ok, {map, _}} = ManageInfrastructure.place(CityMap.new(40, 30), 1, 1, :park)
      map = %{map | money: 10.0}

      assert {:ok, {map, _id}} = ManageInfrastructure.demolish(map, 1, 1)
      assert map.money == 0.0
    end

    test "reports an empty cell before affordability" do
      broke = %{CityMap.new(40, 30) | money: 0.0}

      assert {:error, :empty} = ManageInfrastructure.demolish(broke, 5, 5)
    end
  end
end
