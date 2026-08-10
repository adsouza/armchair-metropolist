defmodule ArmchairMetropolist.UseCases.ResolveUnionDemandTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Services.SimulationCalculator, as: Calc
  alias ArmchairMetropolist.UseCases.ResolveUnionDemand

  test "accepting a demand makes its higher wage costs permanent" do
    city = %{CityMap.new() | money: 1_000.01}

    assert {:ok, settled} = ResolveUnionDemand.execute(city, :accept)
    assert settled.union_wage_level == 1
    assert settled.union_strike_level == 0
    assert settled.revision == 1
    assert Calc.inflation_multiplier(settled) == 1.1
    assert Calc.union_labour_multiplier(settled) == 1.0
    assert Calc.union_demand(settled) == nil
  end

  test "rejecting a demand preserves wages and starts an equivalent strike" do
    city = %{CityMap.new() | money: 2_000.01, union_wage_level: 1}

    assert {:ok, struck} = ResolveUnionDemand.execute(city, :reject)
    assert struck.union_wage_level == 1
    assert struck.union_strike_level == 2
    assert struck.revision == 1
    assert Calc.inflation_multiplier(struck) == 1.1
    assert Calc.union_labour_multiplier(struck) == 0.9

    assert %{pending: false, demanded_wage_percent: 20, strike_percent: 10} =
             Calc.union_demand(struck)
  end

  test "an active strike can later be settled at the demanded wage" do
    city = %{
      CityMap.new()
      | money: 500.0,
        union_wage_level: 1,
        union_strike_level: 2
    }

    assert {:ok, settled} = ResolveUnionDemand.execute(city, :accept)
    assert settled.union_wage_level == 2
    assert settled.union_strike_level == 0
    assert Calc.inflation_multiplier(settled) == 1.2
    assert Calc.union_labour_multiplier(settled) == 1.0
  end

  test "rejecting an already active strike cannot deepen it without a new demand" do
    city = %{CityMap.new() | union_strike_level: 1}
    assert ResolveUnionDemand.execute(city, :reject) == {:error, :already_resolved}
  end

  test "there is nothing to resolve at or below the prosperity threshold" do
    city = %{CityMap.new() | money: Calc.union_demand_threshold()}
    assert ResolveUnionDemand.execute(city, :accept) == {:error, :no_demand}
  end
end
