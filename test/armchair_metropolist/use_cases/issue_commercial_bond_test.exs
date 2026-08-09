defmodule ArmchairMetropolist.UseCases.IssueCommercialBondTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.{CityMap, MunicipalBond, Node}
  alias ArmchairMetropolist.Domain.Services.SimulationCalculator
  alias ArmchairMetropolist.UseCases.IssueCommercialBond

  test "issues the current quote once and preserves the commercial budget for six ticks" do
    city = qualifying_city()

    assert {:ok, issued} = IssueCommercialBond.execute(city)
    assert issued.money == 94.0
    assert issued.revision == city.revision + 1
    assert issued.commercial_bond.original_principal == 94.0
    assert issued.commercial_bond.started_at_tick == city.tick

    after_runway =
      Enum.reduce(1..6, issued, fn _tick, current ->
        elem(SimulationCalculator.advance_tick(current), 0)
      end)

    assert after_runway.money == Node.construction_cost(:commercial)

    assert {:error, :already_issued} = IssueCommercialBond.execute(issued)
  end

  test "rejects a forged request once the bridge conditions no longer hold" do
    city = %{qualifying_city() | money: Node.construction_cost(:commercial)}

    assert {:error, :not_eligible} = IssueCommercialBond.execute(city)
    assert city.commercial_bond == nil
    assert city.revision == 0
  end

  defp qualifying_city do
    city = %{CityMap.new(40, 30) | municipal_bond: MunicipalBond.legacy()}

    city
    |> CityMap.put_node(Node.new(0, 0, :residential))
    |> CityMap.put_node(Node.new(1, 0, :power_plant))
    |> CityMap.put_node(Node.new(2, 0, :water_plant))
  end
end
