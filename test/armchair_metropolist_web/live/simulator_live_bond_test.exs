defmodule ArmchairMetropolistWeb.SimulatorLiveBondTest do
  use ArmchairMetropolistWeb.SimulatorLiveCase

  describe "bond authorization" do
    @tag :unissued_city
    test "a fresh city offers three issues and no interactive grid", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#bond-issuance")
      assert has_element?(view, "#issue-bond-250")
      assert has_element?(view, "#issue-bond-400")
      assert has_element?(view, "#issue-bond-550")
      assert has_element?(view, "#bond-option-400", "Recommended")
      refute has_element?(view, "#city-grid")
    end

    @tag :unissued_city
    test "Balanced shows its exact terms and authorizing it credits proceeds", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      card = view |> element("#bond-option-400") |> render()
      assert card =~ "First debt service"
      assert card =~ "6"
      assert card =~ "On-time interest"
      assert card =~ "101"
      assert card =~ "100 service ticks"

      view |> element("#issue-bond-400") |> render_click()

      assert has_element?(view, "#city-grid")
      assert has_element?(view, "#metrics-treasury", "Treasury: 400")
      assert has_element?(view, "#bond-service-status", "Debt service begins in 20 ticks")
      assert has_element?(view, "#reset-city")
      refute has_element?(view, "#bond-issuance")
    end

    @tag :unissued_city
    test "a rejected construction event does not start or mutate financing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "place", %{"x" => "0", "y" => "0"})

      assert render(view) =~ "Authorize a municipal bond issue before building."
      assert {:ok, %{city_map: city}} = CityEngine.snapshot(CityEngine.default_city_id())
      assert city.tick == 0
      assert city.revision == 0
      assert city.municipal_bond == nil
    end

    @tag :unissued_city
    test "the first successful placement starts but does not consume the holiday", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#issue-bond-400") |> render_click()

      place(view, :residential, 0, 0)

      assert has_element?(view, "#bond-service-status", "Debt service begins in 20 ticks")
      assert {:ok, %{city_map: city}} = CityEngine.snapshot(CityEngine.default_city_id())
      assert city.tick == 0
      assert city.municipal_bond.started_at_tick == 0
    end
  end

  describe "optional redemption and default" do
    @tag :callable_bond
    test "Redeem 25 applies the exact server action", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#redeem-bond-25:not([disabled])")
      view |> element("#redeem-bond-25") |> render_click()

      assert has_element?(view, "#bond-principal", "295")
      assert has_element?(view, "#metrics-treasury", "Treasury: 475")
    end

    @tag :callable_bond
    test "Redeem all retires the issue without reopening authorization", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#redeem-bond-full:not([disabled])")
      view |> element("#redeem-bond-full") |> render_click()

      refute has_element?(view, "#bond-panel")
      assert has_element?(view, "#metrics-panel")
      assert has_element?(view, "#city-grid")
      refute has_element?(view, "#bond-issuance")
    end

    @tag :unissued_city
    test "a forged redemption is refused without changing revision", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "redeem_bond_25", %{})

      assert render(view) =~ "No municipal bond has been issued."
      assert {:ok, %{city_map: city}} = CityEngine.snapshot(CityEngine.default_city_id())
      assert city.revision == 0
      assert city.money == 0.0
    end

    @tag :defaulted_bond
    test "default is explicit and dims every construction row", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#bond-panel .badge", "In default")
      assert has_element?(view, "#bond-interest-arrears", "2")
      assert has_element?(view, "#bond-principal-arrears", "4")
      assert has_element?(view, "#legend-row-residential[data-affordable=false].opacity-40")

      render_click(view, "place", %{"x" => "1", "y" => "0"})
      assert render(view) =~ "clear the past-due balance before building"
    end

    @tag :redeemed_bond
    test "a paid-off issue hides its bond panel without reopening authorization", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#bond-panel")
      assert has_element?(view, "#metrics-panel")
      assert has_element?(view, "#city-grid")
      refute has_element?(view, "#bond-issuance")
    end
  end

  describe "commercial bridge" do
    @tag :bridge_eligible_city
    test "issues the quoted bridge and enables the commercial construction", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#commercial-bond-offer", "6 ticks of projected expenses")

      view |> element("#issue-commercial-bond") |> render_click()

      refute has_element?(view, "#commercial-bond-offer")
      assert has_element?(view, "#metrics-treasury", "Treasury: 94")
      assert has_element?(view, "#commercial-bond-panel")
      assert has_element?(view, "#commercial-bond-principal", "94")

      assert has_element?(
               view,
               "#commercial-bond-service-status",
               "Debt service begins in 20 ticks"
             )

      place(view, :commercial, 3, 0)

      assert has_element?(view, ~s{#nodes [id="3:0"]})
      assert has_element?(view, "#metrics-treasury", "Treasury: 54")
    end

    test "a forged bridge request outside the offer is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "issue_commercial_bond", %{})

      assert render(view) =~ "commercial bridge is no longer available"
      refute has_element?(view, "#commercial-bond-panel")
    end
  end
end
