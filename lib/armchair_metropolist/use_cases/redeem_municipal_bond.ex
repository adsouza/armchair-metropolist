defmodule ArmchairMetropolist.UseCases.RedeemMunicipalBond do
  @moduledoc "Use case: optionally redeem part or all of a callable municipal bond issue."

  alias ArmchairMetropolist.Domain.Entities.{CityMap, MunicipalBond}

  @minimum_redemption 25.0

  @type action :: :minimum | :full
  @type error ::
          :bond_not_issued
          | :legacy_bond
          | :bond_redeemed
          | :not_callable
          | :use_full_redemption
          | :insufficient_funds

  @spec execute(CityMap.t(), action()) :: {:ok, CityMap.t()} | {:error, error()}
  def execute(%CityMap{municipal_bond: nil}, _action), do: {:error, :bond_not_issued}

  def execute(%CityMap{municipal_bond: bond}, _action) when bond.original_principal == 0.0,
    do: {:error, :legacy_bond}

  def execute(%CityMap{} = city_map, action) do
    bond = city_map.municipal_bond

    cond do
      MunicipalBond.debt_free?(bond) ->
        {:error, :bond_redeemed}

      not MunicipalBond.callable?(bond, city_map.tick) ->
        {:error, :not_callable}

      action == :minimum and MunicipalBond.redemption_amount(bond) <= @minimum_redemption ->
        {:error, :use_full_redemption}

      true ->
        redeem(city_map, action)
    end
  end

  defp redeem(city_map, action) do
    amount =
      case action do
        :minimum -> @minimum_redemption
        :full -> MunicipalBond.redemption_amount(city_map.municipal_bond)
      end

    if city_map.money < amount do
      {:error, :insufficient_funds}
    else
      {:ok, bond} = MunicipalBond.redeem(city_map.municipal_bond, city_map.tick, amount)

      next =
        city_map
        |> CityMap.debit(amount)
        |> Map.put(:municipal_bond, bond)
        |> CityMap.increment_revision()

      {:ok, next}
    end
  end
end
