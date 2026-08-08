defmodule ArmchairMetropolistWeb.SimulatorLiveEndStateTest do
  use ArmchairMetropolistWeb.SimulatorLiveCase

  describe "the reset control" do
    test "is absent while the city has living housing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # `select_type` first, and it is not optional. `@selected_type` defaults to
      # `List.first(Node.types())`, and `Node.types/0` is `Map.keys/1` over the capacity
      # table — arbitrary order, so the default is not reliably `residential`. Placing
      # whatever happens to be first would leave `housing_alive` false and this test would
      # assert the opposite of what it claims.
      render_click(view, "select_type", %{"type" => "residential"})
      render_click(view, "place", %{"x" => "1", "y" => "1"})

      refute has_element?(view, "#reset-city")
    end

    test "is absent on a fresh, empty city", %{conn: conn} do
      # No housing alive, but nothing placed and the grant intact — a reset here is a
      # no-op, so offering one is noise.
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
    test "clears the grid and starts a new city", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert render(view) =~ ~s{id="0:0"}

      render_click(view, "wipe")

      html = render(view)
      refute html =~ ~s{id="0:0"}
      assert html =~ "Treasury: #{trunc(CityMap.opening_grant())}"
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

      Phoenix.PubSub.broadcast(ArmchairMetropolist.PubSub, @topic, {:city_reset, CityMap.new()})

      refute render(view) =~ ~s{id="0:0"}
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

      assert length(String.split(html, ~s(phx-click="wipe"))) == 2
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
      # `not housing_alive and (...)`, and this city's house sits at 100 health forever, so
      # the button was unreachable from a city the player can never act in again.
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#reset-city")
    end

    @tag :locked_city
    test "the banner says locked, not dead", %{conn: conn} do
      # A house at 100 health makes "this city is dead" a false sentence. Both directions
      # asserted, because the two banners share their closing advice and an assertion on
      # that alone would pass against the wrong copy.
      {:ok, view, _html} = live(conn, ~p"/")

      html = render(view)
      assert html =~ "City locked"
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
      # 30 in the bank, an 11-tick window, and the park demolition at 10 as the way out.
      # The price matters as much as the verdict: "demolish something" without the 10 does
      # not tell the player whether they can still afford it.
      {:ok, view, _html} = live(conn, ~p"/")

      html = render(view)
      assert html =~ "Upkeep outruns income"
      assert html =~ "11 ticks"
      assert html =~ "park"
      assert html =~ "10"
    end

    @tag :warned_city
    test "a warned city gets no reset control, because it is still rescuable", %{conn: conn} do
      # The warning is an invitation to fix the city, not to abandon it — and the 2026-08-06
      # design's misclick mitigation is exactly that the button stays away from cities the
      # player can still play. `docs/PLAYING.md` claims this in prose; this is what stops the
      # claim going stale.
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#collapse-banner")
      refute has_element?(view, "#reset-city")
    end

    @tag :warned_city
    test "the rescue window appears in the metrics panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#metrics-rescue", "Rescue window: 11 ticks")
    end

    @tag :early_insolvent_city
    test "an insolvent city far from trouble gets neither banner nor rescue line",
         %{conn: conn} do
      # Insolvent but 195 ticks out, past the projection horizon. This is the state the
      # guide's own opening sequence spends five of its seven stages in, so a warning here
      # would fire right through the tutorial.
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#collapse-banner")
      refute has_element?(view, "#metrics-rescue")
      refute has_element?(view, "#reset-city")
    end

    @tag :locked_city
    test "a locked city shows no rescue window, because there is no rescue", %{conn: conn} do
      # `rescue_window` is `0` for this city, and `0` is truthy in Elixir — so a line gated
      # on the bare value renders "Rescue window: 0 ticks" underneath a banner that has just
      # explained the city is over. The figure is a warning device; once the warning is moot
      # it is noise, and "0 ticks to rescue" invites a player to look for the rescue.
      {:ok, view, _html} = live(conn, ~p"/")

      assert html = render(view)
      assert html =~ "City locked"
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
