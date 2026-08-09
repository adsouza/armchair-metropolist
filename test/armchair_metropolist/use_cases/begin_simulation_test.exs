defmodule ArmchairMetropolist.UseCases.BeginSimulationTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.{CityMap, MunicipalBond, Node}
  alias ArmchairMetropolist.UseCases.BeginSimulation

  test "starts an issued city with at least one planned block" do
    {:ok, bond} = MunicipalBond.new(400.0)

    city =
      %{CityMap.new() | municipal_bond: bond, money: 385.0}
      |> CityMap.put_node(Node.new(0, 0, :residential))

    assert {:ok, started} = BeginSimulation.execute(city)
    assert started.municipal_bond.started_at_tick == 0
    assert started.revision == city.revision + 1
    assert started.money == city.money
    assert started.nodes == city.nodes
  end

  test "refuses an empty plan, a missing issue, and a city already running" do
    {:ok, bond} = MunicipalBond.new(400.0)
    planning = %{CityMap.new() | municipal_bond: bond, money: 400.0}

    assert {:error, :empty_city} = BeginSimulation.execute(planning)
    assert {:error, :bond_not_issued} = BeginSimulation.execute(CityMap.new())

    running = %{
      planning
      | municipal_bond: MunicipalBond.start(bond, 0),
        nodes: %{"0:0" => Node.new(0, 0, :residential)}
    }

    assert {:error, :already_started} = BeginSimulation.execute(running)
  end
end
