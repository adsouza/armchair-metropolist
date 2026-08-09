defmodule ArmchairMetropolist.UseCases.IssueMunicipalBondTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.{CityMap, MunicipalBond, Node}
  alias ArmchairMetropolist.UseCases.IssueMunicipalBond

  test "credits authorized proceeds exactly once and increments revision" do
    assert {:ok, city} = IssueMunicipalBond.execute(CityMap.new(), 400.0)
    assert city.money == 400.0
    assert city.revision == 1
    assert city.municipal_bond.original_principal == 400.0
    assert city.municipal_bond.outstanding_principal == 400.0
    assert city.municipal_bond.started_at_tick == nil

    assert {:error, :already_financed} = IssueMunicipalBond.execute(city, 250.0)
    assert city.revision == 1
  end

  test "rejects invalid issues and every non-pristine state without mutation" do
    city = CityMap.new()
    assert {:error, :invalid_issue} = IssueMunicipalBond.execute(city, 300.0)

    non_pristine = [
      %{city | tick: 1},
      %{city | revision: 1},
      %{city | money: 1.0},
      %{city | waste_stock: 1.0},
      CityMap.put_node(city, Node.new(0, 0, :residential))
    ]

    for changed <- non_pristine do
      assert {:error, :not_pristine} = IssueMunicipalBond.execute(changed, 400.0)
      assert changed.municipal_bond == nil
    end
  end

  test "an existing legacy record is already financed" do
    city = %{CityMap.new() | municipal_bond: MunicipalBond.legacy()}
    assert {:error, :already_financed} = IssueMunicipalBond.execute(city, 400.0)
  end
end
