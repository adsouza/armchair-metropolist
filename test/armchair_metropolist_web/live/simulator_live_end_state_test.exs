defmodule ArmchairMetropolistWeb.SimulatorLiveEndStateTest do
  use ArmchairMetropolistWeb.SimulatorLiveCase

  describe "the reset control" do
    test "appears once a living city has been changed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # `select_type` first, and it is not optional. `@selected_type` deliberately defaults
      # to the first canonical type, `power_plant`; placing that would leave `housing_alive`
      # false and this test would assert the opposite of what it claims.
      render_click(view, "select_type", %{"type" => "residential"})
      render_click(view, "place", %{"x" => "1", "y" => "1"})

      assert has_element?(view, "#reset-city")
    end

    @tag :unissued_city
    test "is absent on a fresh, empty city", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#reset-city")
    end

    @tag :stalled_city
    test "appears once no housing is alive", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#reset-city")
    end

    @tag treasury: 9.0
    test "appears on an empty grid that cannot afford to act", %{conn: conn} do
      # The dead end the `node_count > 0` disjunct alone creates: demolish your way down
      # to an empty grid holding 9, and nothing costs 10 or less while an empty grid
      # earns nothing, forever.
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#reset-city")
    end

    @tag :stalled_city
    test "clears the grid and returns to bond authorization", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert render(view) =~ ~s{id="0:0"}

      view |> element("#reset-city") |> render_click()
      assert has_element?(view, "#reset-confirmation")

      view |> element("#confirm-reset") |> render_click()

      html = render(view)
      refute html =~ ~s{id="0:0"}
      assert has_element?(view, "#bond-issuance")
      refute has_element?(view, "#city-grid")
      refute has_element?(view, "#reset-city")
    end

    @tag :stalled_city
    test "another viewer's reset clears this one's grid too", %{conn: conn} do
      # `handle_event("wipe", …)` no longer clears anything itself — it only calls
      # `CityEngine.reset/1` and returns. Because that call is synchronous, the
      # `{:city_reset, city_map}` broadcast is already sitting in this process's own
      # mailbox by the time the call returns, and it is `handle_info({:city_reset, …})`
      # that actually clears the stream and resizes the grid. So deleting that handler
      # would break the click-path test above too, not just this one. What this test
      # still proves and the click path cannot: a reset broadcast from a wipe *this view
      # never issued* still reaches and clears it — the click-path test's wiper and
      # viewer are the same process, so it can never exercise that. Broadcast directly
      # rather than opening a second view, matching the removal test above.
      {:ok, view, _html} = live(conn, ~p"/")
      assert render(view) =~ ~s{id="0:0"}

      view |> element("#reset-city") |> render_click()
      assert has_element?(view, "#reset-confirmation")

      Phoenix.PubSub.broadcast(ArmchairMetropolist.PubSub, @topic, {:city_reset, legacy_city()})

      refute render(view) =~ ~s{id="0:0"}
      refute has_element?(view, "#reset-confirmation")
      assert has_element?(view, ~s{[style*="width: 256px; height: 256px;"]})
    end

    @tag :stalled_city
    test "is sized and coloured for the contrast and target-size floors", %{conn: conn} do
      # Every one of these four classes is a measurement, and every one is invisible to a
      # content assertion — the button is present, labelled `Reset` and clickable without
      # any of them. `min-h-6` is 24px against bare `btn-xs`'s 21px, which fails WCAG 2.2's
      # 24x24 target size; `text-white` is 4.60:1 on `--color-error` against
      # `--color-error-content`'s measured 4.08:1, under the 4.5 floor for small text.
      # Asserted as one exact string so a reordering or a dropped class both go red, and
      # scoped to the button's own id so it cannot pass against some other element.
      {:ok, view, _html} = live(conn, ~p"/")

      assert view |> element("#reset-city") |> render() =~
               ~s(class="btn btn-xs btn-error text-white min-h-6")
    end

    @tag :stalled_city
    test "is labelled Reset", %{conn: conn} do
      # Nothing else in the suite reads this string. Both banners below tell the player
      # to press "Reset in the header" — relabelling this button would leave every test
      # above green while stranding that instruction against a button that no longer
      # says what they claim it says.
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#reset-city", "Reset")
    end

    test "asks for confirmation and can keep a playable city", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "select_type", %{"type" => "residential"})
      render_click(view, "place", %{"x" => "1", "y" => "1"})

      view |> element("#reset-city") |> render_click()

      assert has_element?(view, "#reset-confirmation[role='dialog']")
      assert has_element?(view, "#cancel-reset", "Keep city")
      assert has_element?(view, "#confirm-reset", "Discard and reset")

      view |> element("#cancel-reset") |> render_click()

      refute has_element?(view, "#reset-confirmation")
      assert has_element?(view, ~s{#nodes [id="1:1"]})
    end
  end

  describe "the collapse banner" do
    @tag :stalled_city
    test "says the city is dead when nothing can restart it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#collapse-banner")
      assert render(view) =~ "Game over — this city is dead."
    end

    @tag :stalled_solvent_city
    test "says the city is stalled while a rescue is still affordable", %{conn: conn} do
      # Both banners share their second sentence, so asserting on the shared prose would
      # pass against the wrong state. The headline is the only text that separates them,
      # which is why both directions are asserted here.
      {:ok, view, _html} = live(conn, ~p"/")

      html = render(view)
      assert html =~ "City stalled — nothing is changing on its own."
      refute html =~ "this city is dead"
    end

    test "is absent while the city is running", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#collapse-banner")
    end

    @tag :stalled_city
    test "is as wide as the grid", %{conn: conn} do
      # Scoped to the banner's own id. A bare `html =~ "width: 960px"` would pass with no
      # banner rendered at all, because the grid container carries that same width — the
      # assertion would be incapable of failing.
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s{#collapse-banner[style*="width: #{40 * 24}px"]})
    end

    @tag :stalled_city
    test "does not render a second reset control", %{conn: conn} do
      # The banner names the header's button rather than repeating it. A later edit that
      # helpfully adds one back would ship duplicate DOM ids and a second untested event
      # path, and nothing else in the suite would notice.
      {:ok, _view, html} = live(conn, ~p"/")

      assert length(String.split(html, ~s(id="reset-city"))) == 2
    end

    @tag :stalled_solvent_city
    test "points the player at the header's Reset button", %{conn: conn} do
      # The other half of the coupling pinned by "is labelled Reset" above: this banner
      # names the button rather than rendering one of its own, so the two assertions
      # together are what would catch a relabelling that the rest of the suite misses.
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#collapse-banner", "Reset")
    end
  end

  describe "insolvency" do
    @tag :locked_city
    test "the reset control appears on a locked city that still has living housing",
         %{conn: conn} do
      # The defect this whole feature exists to fix. `show_reset?/1` was
      # `not housing_alive and (...)`, and this city's supported house sits at 100 health forever, so
      # the button was unreachable from a city the player can never act in again.
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#reset-city")
    end

    @tag :bridge_eligible_city
    test "an operating lock offers a commercial bridge instead of declaring game over",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render(view)
      assert has_element?(view, "#commercial-bond-offer")
      assert has_element?(view, "#issue-commercial-bond", "Issue 94 bridge bond")
      refute html =~ "City locked"
      refute html =~ "this city is dead"
    end

    @tag :locked_city
    test "a city that already used its bridge is locked, not dead", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render(view)
      assert html =~ "City locked"
      refute has_element?(view, "#commercial-bond-offer")
      refute html =~ "this city is dead"
    end

    @tag :stalled_city
    test "a stalled bankrupt city still says dead rather than locked", %{conn: conn} do
      # Banner precedence. A stalled city is *also* insolvent whenever its upkeep outruns
      # its ceiling, so both new and old copy qualify and the order decides. Dead is the
      # more specific truth when every block is on the floor. Kills swapping the two rows.
      {:ok, view, _html} = live(conn, ~p"/")

      html = render(view)
      assert html =~ "Game over — this city is dead."
      refute html =~ "City locked"
    end

    @tag :warned_city
    test "warns before bankruptcy and names the escape with its price", %{conn: conn} do
      # 30 in the bank, a 2-tick window, and the park demolition at 10 as the way out.
      # The price matters as much as the verdict: "demolish something" without the 10 does
      # not tell the player whether they can still afford it.
      {:ok, view, _html} = live(conn, ~p"/")

      html = render(view)
      assert html =~ "Upkeep outruns income"
      assert html =~ "2 ticks"
      assert html =~ "park"
      assert html =~ "10"
    end

    @tag :warned_city
    test "a warned city can still be reset", %{conn: conn} do
      # Reset is an escape hatch chosen by the player, not a verdict that the city is dead.
      # The button's confirmation prompt protects this still-rescuable city from a stray
      # click while leaving the option available.
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#collapse-banner")
      assert has_element?(view, "#reset-city")
    end

    @tag :warned_city
    test "the bridge replaces the rescue window once commercial construction is unaffordable",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#commercial-bond-offer", "40 needed for 1 commercial block")
      refute has_element?(view, "#metrics-rescue")
    end

    @tag :early_insolvent_city
    test "an insolvent city far from trouble gets no warning but can still be reset",
         %{conn: conn} do
      # Insolvent but past the projection horizon. This is the state the
      # guide's own opening sequence enters at its third stage, so a warning here
      # would fire right through the tutorial. Reset remains available because the player
      # has already changed the city; its presence is not itself a warning.
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#collapse-banner")
      refute has_element?(view, "#metrics-rescue")
      assert has_element?(view, "#reset-city")
    end

    @tag :bridge_eligible_city
    test "the bridge offer replaces the stale zero-tick rescue line", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#commercial-bond-offer")
      refute has_element?(view, "#metrics-rescue")
    end

    test "a healthy city has no rescue line at all", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "select_type", %{"type" => "residential"})
      render_click(view, "place", %{"x" => "1", "y" => "1"})

      refute has_element?(view, "#metrics-rescue")
    end
  end
end
