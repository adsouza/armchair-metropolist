defmodule ArmchairMetropolist.Domain.Entities.MunicipalBondTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.MunicipalBond

  describe "issue terms" do
    test "constructs only the three authorized issue sizes" do
      for principal <- [250.0, 400.0, 550.0] do
        assert {:ok, bond} = MunicipalBond.new(principal)
        assert bond.original_principal == principal
        assert bond.outstanding_principal == principal
      end

      assert {:error, :invalid_issue} = MunicipalBond.new(399.0)
      assert MunicipalBond.recommended_issue() == 400.0
      assert MunicipalBond.opening_period_ticks() == 20
      assert MunicipalBond.call_protection_ticks() == 20
      assert MunicipalBond.term_ticks() == 100
      assert MunicipalBond.interest_rate() == 0.005

      assert MunicipalBond.issue_terms(250.0).first_payment == 3.75
      assert MunicipalBond.issue_terms(400.0).total_interest == 101.0
      assert_in_delta MunicipalBond.issue_terms(550.0).total_interest, 138.875, 1.0e-9
    end

    test "legacy, issued, defaulted, and debt-free states are distinct" do
      legacy = MunicipalBond.legacy()
      {:ok, issued} = MunicipalBond.new(400.0)
      defaulted = %{issued | interest_arrears: 1.0}
      redeemed = %{issued | outstanding_principal: 0.0}

      assert MunicipalBond.legacy?(legacy)
      assert MunicipalBond.debt_free?(legacy)
      refute MunicipalBond.issued?(legacy)

      assert MunicipalBond.issued?(issued)
      refute MunicipalBond.debt_free?(issued)
      refute MunicipalBond.defaulted?(issued)

      assert MunicipalBond.defaulted?(defaulted)
      assert MunicipalBond.debt_free?(redeemed)
      refute MunicipalBond.legacy?(redeemed)
    end
  end

  describe "schedule" do
    setup do
      {:ok, bond} = MunicipalBond.new(400.0)
      %{bond: MunicipalBond.start(bond, 0)}
    end

    test "starts once and leaves the first 20 transitions debt-service free", %{bond: bond} do
      assert MunicipalBond.start(bond, 9).started_at_tick == 0
      assert MunicipalBond.quote(bond, 0).opening_period_remaining == 20
      assert MunicipalBond.quote(bond, 19).opening_period_remaining == 1
      assert MunicipalBond.service(bond, 19, 1_000.0).payment == 0.0

      quote = MunicipalBond.quote(bond, 20)
      assert quote.opening_period_remaining == 0
      assert quote.next_interest == 2.0
      assert quote.next_principal == 4.0
      assert quote.next_payment == 6.0
    end

    test "amortizes on time to exact zero in 100 payments", %{bond: bond} do
      {payments, bond} =
        Enum.map_reduce(20..119, bond, fn tick, current ->
          %{bond: next, payment: payment} = MunicipalBond.service(current, tick, 10_000.0)
          {payment, next}
        end)

      assert bond.outstanding_principal == 0.0
      assert bond.interest_arrears == 0.0
      assert bond.principal_arrears == 0.0
      assert_in_delta Enum.sum(payments), 501.0, 1.0e-9
    end

    test "tracks missed principal as a subset and never schedules it twice", %{bond: bond} do
      %{bond: missed} = MunicipalBond.service(bond, 20, 0.0)

      assert missed.outstanding_principal == 400.0
      assert missed.interest_arrears == 2.0
      assert missed.principal_arrears == 4.0
      assert MunicipalBond.quote(missed, 21).next_principal == 8.0

      %{bond: partial} = MunicipalBond.service(missed, 21, 6.0)
      assert partial.outstanding_principal == 398.0
      assert partial.interest_arrears == 0.0
      assert partial.principal_arrears == 6.0
      assert partial.principal_arrears <= partial.outstanding_principal
    end

    test "final maturity makes every remaining principal past due", %{bond: bond} do
      %{bond: matured} = MunicipalBond.service(bond, 119, 0.0)

      assert matured.principal_arrears == matured.outstanding_principal
      assert MunicipalBond.defaulted?(matured)
      assert MunicipalBond.quote(matured, 120).maturity_remaining == 0
    end
  end

  describe "optional redemption" do
    test "opens after 20 servicing ticks and allocates arrears before principal" do
      {:ok, bond} = MunicipalBond.new(400.0)
      bond = MunicipalBond.start(bond, 0)

      refute MunicipalBond.callable?(bond, 39)
      assert {:error, :not_callable} = MunicipalBond.redeem(bond, 39, 25.0)
      assert MunicipalBond.callable?(bond, 40)

      bond = %{bond | interest_arrears: 5.0, principal_arrears: 10.0}
      assert {:ok, redeemed} = MunicipalBond.redeem(bond, 40, 25.0)
      assert redeemed.interest_arrears == 0.0
      assert redeemed.outstanding_principal == 380.0
      assert redeemed.principal_arrears == 0.0
    end

    test "full redemption assigns exact zero and does not turn the issue into unissued" do
      {:ok, bond} = MunicipalBond.new(250.0)
      bond = MunicipalBond.start(bond, 0)

      assert {:ok, redeemed} =
               MunicipalBond.redeem(bond, 40, MunicipalBond.redemption_amount(bond))

      assert redeemed.original_principal == 250.0
      assert redeemed.outstanding_principal == 0.0
      assert redeemed.interest_arrears == 0.0
      assert redeemed.principal_arrears == 0.0
      assert MunicipalBond.debt_free?(redeemed)
      refute MunicipalBond.legacy?(redeemed)
    end
  end
end
