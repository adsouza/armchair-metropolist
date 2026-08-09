defmodule ArmchairMetropolist.UseCases.RedeemMunicipalBondTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.{CityMap, MunicipalBond}
  alias ArmchairMetropolist.UseCases.RedeemMunicipalBond

  test "redeems 25 or the exact balance after call protection" do
    city = callable_city(100.0)

    assert {:ok, partial} = RedeemMunicipalBond.execute(city, :minimum)
    assert partial.money == 75.0
    assert partial.municipal_bond.outstanding_principal == 375.0
    assert partial.revision == city.revision + 1

    amount = MunicipalBond.redemption_amount(partial.municipal_bond)
    partial = %{partial | money: amount}
    assert {:ok, redeemed} = RedeemMunicipalBond.execute(partial, :full)
    assert redeemed.money == 0.0
    assert MunicipalBond.debt_free?(redeemed.municipal_bond)
  end

  test "returns every state and affordability error without changing revision" do
    fresh = CityMap.new()
    assert {:error, :bond_not_issued} = RedeemMunicipalBond.execute(fresh, :full)

    legacy = %{fresh | municipal_bond: MunicipalBond.legacy()}
    assert {:error, :legacy_bond} = RedeemMunicipalBond.execute(legacy, :full)

    protected = issued_city(100.0, 39)
    assert {:error, :not_callable} = RedeemMunicipalBond.execute(protected, :minimum)

    callable = callable_city(0.0)
    assert {:error, :insufficient_funds} = RedeemMunicipalBond.execute(callable, :minimum)

    nearly_redeemed = %{
      callable
      | money: 30.0,
        municipal_bond: %{
          callable.municipal_bond
          | outstanding_principal: 20.0
        }
    }

    assert {:error, :use_full_redemption} =
             RedeemMunicipalBond.execute(nearly_redeemed, :minimum)

    redeemed = %{
      callable
      | municipal_bond: %{callable.municipal_bond | outstanding_principal: 0.0}
    }

    assert {:error, :bond_redeemed} = RedeemMunicipalBond.execute(redeemed, :full)

    for city <- [fresh, legacy, protected, callable, nearly_redeemed, redeemed] do
      assert city.revision in [0, 1]
    end
  end

  defp callable_city(money), do: issued_city(money, 40)

  defp issued_city(money, tick) do
    {:ok, bond} = MunicipalBond.new(400.0)

    %{
      CityMap.new()
      | municipal_bond: MunicipalBond.start(bond, 0),
        money: money,
        tick: tick,
        revision: 1
    }
  end
end
