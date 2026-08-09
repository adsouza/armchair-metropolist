defmodule ArmchairMetropolist.UseCases.QuickStartTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.{CityMap, MunicipalBond, Node}
  alias ArmchairMetropolist.UseCases.QuickStart

  test "adds one of every starter type, charges their exact cost, and grows as needed" do
    {:ok, bond} = MunicipalBond.new(400.0)
    city = %{CityMap.new() | municipal_bond: bond, money: QuickStart.cost()}

    assert {:ok, %{city_map: started, nodes: nodes}} = QuickStart.execute(city)

    assert Enum.map(nodes, & &1.type) == QuickStart.types()

    assert Enum.frequencies_by(CityMap.nodes(started), & &1.type) == %{
             power_plant: 1,
             commercial: 1,
             water_plant: 1,
             residential: 1,
             park: 1
           }

    assert started.money == 0.0
    assert started.revision == 5
    assert {started.width, started.height} == {4, 4}
  end

  test "adds the complete starter set without replacing an existing plan" do
    {:ok, bond} = MunicipalBond.new(550.0)

    city =
      %{CityMap.new() | municipal_bond: bond, money: 550.0}
      |> CityMap.put_node(Node.new(0, 0, :park))

    assert {:ok, %{city_map: started}} = QuickStart.execute(city)

    assert map_size(started.nodes) == 6
    assert Enum.count(CityMap.nodes(started), &(&1.type == :park)) == 2
    assert CityMap.get_node(started, 0, 0).type == :park
    assert started.money == 550.0 - QuickStart.cost()
  end

  test "refuses an unaffordable or already-running plan without returning partial work" do
    {:ok, bond} = MunicipalBond.new(400.0)
    planning = %{CityMap.new() | municipal_bond: bond, money: QuickStart.cost() - 1.0}

    assert {:error, :insufficient_funds} = QuickStart.execute(planning)

    running = %{planning | municipal_bond: MunicipalBond.start(bond, 0), money: 400.0}
    assert {:error, :already_started} = QuickStart.execute(running)
  end
end
