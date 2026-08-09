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
      assert has_element?(view, "#opening-planning", "Design before the clock starts")
      assert has_element?(view, "#begin-sim[disabled]")
      assert has_element?(view, "#bond-service-status", "Debt service begins after Begin sim")
      assert has_element?(view, "#bond-panel.w-fit")
      assert has_element?(view, "#metrics-treasury + #bond-panel")
      assert has_element?(view, "#bond-panel + #metrics-market-slot")
      assert has_element?(view, "#bond-redemption-actions.grid.w-fit")
      assert has_element?(view, "#opening-goal-banner[data-variant=opening_goal] #opening-goal")

      assert has_element?(
               view,
               "#opening-planning ~ #simulator-layout #city-column > #opening-goal-banner + #city-grid"
             )

      assert has_element?(view, "#opening-goal", "Suggested goal 1 of 4")
      assert has_element?(view, "#opening-goal", "Cover power locally")
      assert has_element?(view, "#reset-city")
      refute has_element?(view, "#bond-issuance")
    end

    @tag :unissued_city
    test "opening suggestions advance from power to income, viability, and readiness", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#issue-bond-400") |> render_click()

      place(view, :power_plant, 0, 0)
      assert has_element?(view, "#opening-goal", "Suggested goal 2 of 4")
      assert has_element?(view, "#opening-goal", "Establish positive operating income")

      place(view, :commercial, 1, 0)
      assert has_element?(view, "#opening-goal", "Suggested goal 3 of 4")
      assert has_element?(view, "#opening-goal", "Establish a local workforce")
      assert has_element?(view, "#opening-goal", "9 imported workers")

      place(view, :residential, 0, 1)
      assert has_element?(view, "#opening-goal", "Suggested goal 4 of 4")
      assert has_element?(view, "#opening-goal", "Review the plan, then begin")

      place(view, :residential, -1, 0)
      assert has_element?(view, "#opening-goal", "Suggested goal 3 of 4")
      assert has_element?(view, "#opening-goal", "Make the plan self-funding")

      place(view, :water_plant, -1, 1)
      assert has_element?(view, "#opening-goal", "Suggested goal 4 of 4")
      assert has_element?(view, "#opening-goal", "Review the plan, then begin")

      view |> element("#begin-sim") |> render_click()
      assert has_element?(view, "#opening-goal", "Use the grace period to build a reserve")
    end

    @tag :unissued_city
    test "quick start adds one of each starter block during planning", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#issue-bond-400") |> render_click()

      assert has_element?(view, "#quick-start:not([disabled])", "Quick start")
      view |> element("#quick-start") |> render_click()

      for type <- [:power_plant, :commercial, :water_plant, :residential, :park] do
        assert has_element?(view, ~s{#legend-row-#{type}[data-count="1"]})
      end

      assert has_element?(view, "#metrics-treasury", "Treasury: 175")
      assert has_element?(view, "#begin-sim:not([disabled])")

      assert {:ok, %{city_map: city}} = CityEngine.snapshot(CityEngine.default_city_id())

      assert Enum.frequencies_by(CityMap.nodes(city), & &1.type) == %{
               power_plant: 1,
               commercial: 1,
               water_plant: 1,
               residential: 1,
               park: 1
             }

      view |> element("#begin-sim") |> render_click()
      refute has_element?(view, "#quick-start")
    end

    @tag :unissued_city
    test "the Balanced opening recommends saving without removing its parks", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#issue-bond-400") |> render_click()

      for {type, x, y} <- [
            {:residential, 0, 0},
            {:power_plant, 1, 0},
            {:transit_hub, 0, 1},
            {:commercial, 1, 1},
            {:water_plant, 2, 0},
            {:residential, 2, 1},
            {:park, -1, 0},
            {:park, -1, 1}
          ] do
        place(view, type, x, y)
      end

      view |> element("#begin-sim") |> render_click()

      assert has_element?(view, "#opening-goal", "Keep both parks")
      assert has_element?(view, "#opening-goal", "save toward 450")
      assert has_element?(view, "#opening-goal", "preserving a 100 reserve")
    end

    @tag :unissued_city
    test "goal 3 keeps a cheap labour import when another house would cost more", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#issue-bond-400") |> render_click()

      for {type, x, y} <- [
            {:power_plant, 0, 0},
            {:commercial, 1, 0},
            {:residential, 0, 1},
            {:park, -1, 0},
            {:water_plant, -1, 1}
          ] do
        place(view, type, x, y)
      end

      # This layout imports one worker. Another house would eliminate that purchase but
      # overrun waste capacity by four, lowering operating margin despite its one income.
      assert has_element?(
               view,
               ~s{#metrics-market [data-market-resource="labour"]},
               "labour +1.0"
             )

      assert has_element?(view, "#opening-goal", "Suggested goal 4 of 4")
      assert has_element?(view, "#opening-goal", "Review the plan, then begin")
      refute has_element?(view, "#opening-goal", "Establish a local workforce")
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
    test "planning supports repeated full-refund undo and Begin sim starts the holiday", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#issue-bond-400") |> render_click()

      for _attempt <- 1..2 do
        place(view, :park, 0, 0)

        assert has_element?(view, "#metrics-treasury", "Treasury: 380")
        assert has_element?(view, "#begin-sim:not([disabled])")

        planned_node = view |> element(~s{[phx-click="demolish"][phx-value-x="0"]}) |> render()
        assert planned_node =~ "full 20 refund"

        view
        |> element(~s{[phx-click="demolish"][phx-value-x="0"][phx-value-y="0"]})
        |> render_click()

        assert has_element?(view, "#metrics-treasury", "Treasury: 400")
        assert has_element?(view, "#begin-sim[disabled]")
      end

      place(view, :residential, 0, 0)

      assert has_element?(view, "#opening-planning")
      assert has_element?(view, "#bond-service-status", "Debt service begins after Begin sim")

      view |> element("#begin-sim") |> render_click()

      assert has_element?(view, "#bond-service-status", "Debt service begins in 20 ticks")
      refute has_element?(view, "#opening-planning")
      assert has_element?(view, "#opening-goal", "Cover power locally")

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
      assert has_element?(view, "#metrics-treasury + #commercial-bond-panel")
      assert has_element?(view, "#commercial-bond-panel + #metrics-market-slot")
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
