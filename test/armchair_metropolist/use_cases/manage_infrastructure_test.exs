defmodule ArmchairMetropolist.UseCases.ManageInfrastructureTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.CityMap
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

    test "place then demolish round-trips to the original map", %{map: map} do
      {:ok, {placed, _}} = ManageInfrastructure.place(map, 5, 5, :industrial)
      {:ok, {restored, _}} = ManageInfrastructure.demolish(placed, 5, 5)
      assert restored == map
    end
  end
end
