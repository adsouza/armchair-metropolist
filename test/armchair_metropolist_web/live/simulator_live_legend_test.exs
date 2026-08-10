defmodule ArmchairMetropolistWeb.SimulatorLiveLegendTest do
  use ArmchairMetropolistWeb.SimulatorLiveCase

  describe "legend" do
    test "explains that tapping a block type name selects it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert view |> element("#legend-heading #legend-selection-hint") |> render() =~
               "tap on the name of a block type to select it"
    end

    test "shows each block emoji immediately before its type label", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      for {type, emoji} <- @block_emojis do
        selector = ~s{#legend-row-#{type} button}

        assert has_element?(view, "#{selector} > span[aria-hidden=true] + span")
        assert view |> element(selector) |> render() =~ "gap-1.5"

        text =
          view
          |> element(selector)
          |> render()
          |> LazyHTML.from_fragment()
          |> LazyHTML.text()
          |> String.split()
          |> Enum.join(" ")

        assert text == "#{emoji}#{type}"
      end
    end

    test "renders block rows in the canonical node-type order", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      for {type, position} <- Enum.with_index(Node.types(), 1) do
        assert has_element?(
                 view,
                 "#block-legend tbody > tr#legend-row-#{type}:nth-child(#{position})"
               )
      end
    end

    test "keeps the matrix columns at their compact intrinsic width", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      table = view |> element("#block-legend") |> render()

      assert has_element?(view, ~s{#legend-panel.shrink-0[style="width: 760px;"]})
      assert has_element?(view, "#block-legend.w-fit")
      assert table =~ "[&amp;_th]:px-1"
      assert table =~ "[&amp;_td]:px-1"
    end

    test "keeps stock resources out of the matrix and summarizes their treatment",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, ~s{[data-cell="hospital-injuries"]})
      refute has_element?(view, ~s{[data-cell="hospital-disease"]})
      refute has_element?(view, ~s{[data-total="injuries"]})
      refute has_element?(view, ~s{[data-total="disease"]})
      refute has_element?(view, ~s{[data-cell="police_station-crime"]})
      refute has_element?(view, ~s{[data-cell="school-crime"]})
      refute has_element?(view, ~s{[data-total="crime"]})

      treatment = view |> element("#hospital-treatment-summary") |> render()
      assert treatment =~ "-10 injuries/disease"
      assert view |> element("#police_station-crime-treatment-summary") |> render() =~ "-12 crime"
      assert view |> element("#school-crime-treatment-summary") |> render() =~ "-6 crime"
    end

    test "shows crime at its normal zero baseline", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert view |> element("#metrics-crime") |> render() =~ "Crime: 0.0 · commerce ×1.0"
    end

    @tag treasury: 2_000.0
    test "shows active inflation and its adjusted construction prices", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert view |> element("#metrics-inflation") |> render() =~ "Inflation: +10%"
      assert view |> element(~s{[data-cell="commercial-cost"]}) |> render() =~ "44"
    end

    test "wraps the totals footnote and reports the free baselines", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#simulator-layout + #legend-footnote")
      assert has_element?(view, "#legend-footnote.max-w-3xl")
      assert has_element?(view, "#legend-footnote > #city-reentry")
      refute has_element?(view, "#simulator-layout #city-reentry")
      refute has_element?(view, "#legend-and-metrics #legend-footnote")

      footnote = view |> element("#legend-footnote") |> render()
      assert footnote =~ "30 water supplied, 40 waste"
      assert footnote =~ "30 traffic absorbed"
    end

    # Two power plants at 80 each is 160, comfortably inside this legacy fixture's treasury —
    # measured, this test passes with the tag removed, so the treasury is insulation
    # rather than necessity. It is kept because it pins a round balance that neither the
    # treasury nor the construction cost can move: `power_plant` would have to pass 500
    # before two of them stopped fitting the fixture unaided, and a test about legend
    # rendering should not start failing on a balance patch it has no opinion about.
    #
    # This is grandfathered test state, not a new-city financing path.
    #
    # The type is not negotiable for this block: the `+120` and `+360` figures two of
    # these tests pin are power_plant capacity, so switching to a cheaper type would turn
    # a fixture fix into a rebalance of the test's own subject.
    @tag treasury: 1_000.0
    test "shows how many of each type are placed, updating as you place", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Every type has a row from the start, including ones with nothing placed.
      assert has_element?(view, "#legend-row-industrial")
      assert has_element?(view, ~s{#legend-row-power_plant[data-count="0"]})

      view
      |> element(~s{button[phx-click="select_type"][phx-value-type="power_plant"]})
      |> render_click()

      view |> element(~s{[phx-click="place"][phx-value-x="1"][phx-value-y="1"]}) |> render_click()
      view |> element(~s{[phx-click="place"][phx-value-x="2"][phx-value-y="1"]}) |> render_click()

      # Depends on Task 2: without the command-time broadcast this stays at 0.
      assert has_element?(view, ~s{#legend-row-power_plant[data-count="2"]})

      # `data-count` is a test hook; the cell is the number a player actually reads,
      # and nothing tied the two together — the cell could be hard-coded and the
      # attribute would still say 2.
      assert view |> element(~s{[data-cell="power_plant-count"]}) |> render() =~ "2"
    end

    test "a producing cell shows the type's net effect on that resource", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element(~s{button[phx-click="select_type"][phx-value-type="power_plant"]})
      |> render_click()

      view |> element(~s{[phx-click="place"][phx-value-x="1"][phx-value-y="1"]}) |> render_click()

      # One power plant: power +120, water -20.
      assert view |> element(~s{[data-cell="power_plant-power"]}) |> render() =~ "+120"
      assert view |> element(~s{[data-cell="power_plant-water"]}) |> render() =~ "-20"
    end

    # The gap this fixes: every figure in a row was multiplied by the count, so a type
    # with nothing placed read "+0" everywhere — no help at all in deciding what to
    # place, which is exactly when a player consults the legend.
    test "a type with none placed still shows what one block would do", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s{#legend-row-power_plant[data-count="0"]}),
             "precondition: nothing placed"

      power = view |> element(~s{[data-cell="power_plant-power"]}) |> render()

      assert power =~ "+120", "must show the per-block figure with none placed"

      # And no city total line, because there is no city yet — a "0" would be noise.
      # Refuted against `font-semibold`, the total line's own class, because that is
      # what the markup actually emits: an earlier version of this refuted the word
      # "total", which appears nowhere, and passed against a deliberately broken
      # build. The next test asserts this class *is* present once blocks exist, so
      # the refutation has a state in which it fails.
      refute power =~ "font-semibold"
    end

    # Three power plants at 80 each is 240, inside the legacy fixture's treasury — measured, this
    # test passes with the tag removed too. Kept for the same reason as the block above,
    # and the margin here is the thinner of the two: `power_plant` passing 133 would take
    # three of them past that balance, where two would still fit until 500.
    @tag treasury: 1_000.0
    test "placing blocks adds a city total beside the per-block figure", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element(~s{button[phx-click="select_type"][phx-value-type="power_plant"]})
      |> render_click()

      for {x, y} <- [{5, 5}, {6, 5}, {7, 5}] do
        view
        |> element(~s{[phx-click="place"][phx-value-x="#{x}"][phx-value-y="#{y}"]})
        |> render_click()
      end

      power = view |> element(~s{[data-cell="power_plant-power"]}) |> render()

      # Per block stays constant; the total is three of them.
      assert power =~ "+120", "the per-block figure must not scale with count"
      assert power =~ "+360", "three plants must total +360"

      assert power =~ "font-semibold",
             "the total line must appear once blocks exist — the positive case for the " <>
               "refutation in the test above"
    end

    test "a resource the type never touches shows an em dash, not a zero", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Positive case first: a transit hub does consume power, so that cell holds a number.
      # The specific figure, not the incidental "0" the old count-scaled cell rendered.
      assert view |> element(~s{[data-cell="transit_hub-power"]}) |> render() =~ "-8"

      # It never touches water, and that must read differently from "nets to zero".
      # No `refute water =~ "0"` here: the assert above already carries the claim, and
      # any mutation that reaches this line has failed it. What the refute could still
      # do is false-fail the day someone adds a class or attribute containing a "0".
      assert view |> element(~s{[data-cell="transit_hub-water"]}) |> render() =~ "—"
    end

    test "the totals row reports demand against capacity, and satisfaction per resource",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:city_metrics, metrics_with_distinct_satisfaction()})
      render(view)

      # Demand first, capacity second, for every resource. The fixture's two figures
      # differ per resource, so a transposed pair reads as wrong rather than as itself.
      assert view |> element(~s{[data-total="power"]}) |> render() =~ "120/150"
      assert view |> element(~s{[data-total="water"]}) |> render() =~ "70/35"

      # The negative resources take the *same* order — that is the point of unifying
      # on demand-first. An ordering swap applied only to waste and traffic passes the
      # two assertions below and fails the two above; one applied only to the positive
      # resources does the reverse. Both pairs are needed.
      assert view |> element(~s{[data-total="waste"]}) |> render() =~ "80/60"
      assert view |> element(~s{[data-total="traffic"]}) |> render() =~ "100/25"

      assert view |> element(~s{[data-total="power"]}) |> render() =~ "100.0%"
      assert view |> element(~s{[data-total="water"]}) |> render() =~ "50.0%"
      assert view |> element(~s{[data-total="waste"]}) |> render() =~ "75.0%"
      assert view |> element(~s{[data-total="traffic"]}) |> render() =~ "25.0%"

      # The header names the order. It is a decision, so a silent revert to
      # supplied/demanded must redden something.
      label =
        view
        |> element("#legend-totals > th:first-child")
        |> render()

      assert has_element?(view, "#legend-totals > th:first-child > div + div")
      assert label =~ "demanded/supplied"
      assert label =~ "met this tick"
      refute label =~ "·"

      # The resource cells use the same two-line treatment; splitting only the label
      # would leave values such as `120/150 · 100.0%` setting the column width.
      assert has_element?(view, ~s{[data-total="power"] > div + div})
      refute view |> element(~s{[data-total="power"]}) |> render() =~ "·"
    end

    test "the totals row warns near capacity and turns red on a shortfall", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      metrics = %{
        empty_city_metrics()
        | resources: %{
            power: stat(111.0, 100.0),
            water: stat(110.0, 100.0),
            waste: stat(100.0, 100.0),
            traffic: stat(99.0, 100.0)
          }
      }

      send(view.pid, {:city_metrics, metrics})
      render(view)

      healthy = view |> element(~s{[data-total="power"]}) |> render()
      warning = view |> element(~s{[data-total="water"]}) |> render()
      exact = view |> element(~s{[data-total="waste"]}) |> render()
      shortfall = view |> element(~s{[data-total="traffic"]}) |> render()

      assert healthy =~ ~s(data-supply-status="healthy")
      refute healthy =~ "text-orange-700"
      refute healthy =~ "text-red-700"

      for cell <- [warning, exact] do
        assert cell =~ ~s(data-supply-status="warning")
        assert cell =~ "text-orange-700"
        assert cell =~ "dark:text-orange-300"
        refute cell =~ "text-red-700"
      end

      assert shortfall =~ ~s(data-supply-status="shortfall")
      assert shortfall =~ "text-red-700"
      assert shortfall =~ "dark:text-red-300"
      refute shortfall =~ "text-orange-700"
    end

    test "purchased capacity is identified by resource in totals and metrics",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      power =
        stat(40.0, 60.0)
        |> Map.merge(%{purchased: 20.0, deficit: 0.0, satisfaction: 1.0, flow_satisfaction: 1.0})

      water =
        stat(30.0, 35.0)
        |> Map.merge(%{purchased: 5.0, deficit: 0.0, satisfaction: 1.0, flow_satisfaction: 1.0})

      metrics = %{
        empty_city_metrics()
        | resources: %{power: power, water: water},
          market_spend: 25.0
      }

      send(view.pid, {:city_metrics, metrics})
      render(view)

      assert view |> element(~s{[data-total="power"]}) |> render() =~ "60/60"
      assert view |> element(~s{[data-total="power"]}) |> render() =~ "100.0%"

      assert view
             |> element(~s{[data-total="power"] [data-purchased-resource="power"]})
             |> render() =~ "+20.0 bought"

      assert view
             |> element(~s{[data-total="water"] [data-purchased-resource="water"]})
             |> render() =~ "+5.0 bought"

      refute has_element?(view, ~s{[data-purchased-resource="traffic"]})

      assert view |> element("#metrics-market") |> render() =~
               "Automatic purchases: 25.0/tick"

      assert has_element?(view, "#metrics-market > span.block.tabular-nums")
      assert has_element?(view, "#metrics-market > span.mt-1.flex.flex-wrap")

      assert view |> element(~s{#metrics-market [data-market-resource="power"]}) |> render() =~
               "power +20.0"

      assert view |> element(~s{#metrics-market [data-market-resource="water"]}) |> render() =~
               "water +5.0"

      footnote =
        view
        |> element("#legend-footnote")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
        |> String.replace(~r/\s+/, " ")

      assert footnote =~ "1 money per unit"
    end

    test "imported labour reports its commuter traffic penalty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      labour =
        stat(0.0, 3.0)
        |> Map.merge(%{purchased: 3.0, deficit: 0.0, satisfaction: 1.0, flow_satisfaction: 1.0})

      metrics = %{
        empty_city_metrics()
        | resources: %{labour: labour},
          market_spend: 3.0,
          imported_labour_traffic: 3.0
      }

      send(view.pid, {:city_metrics, metrics})
      render(view)

      assert view
             |> element("#metrics-imported-labour-traffic")
             |> render() =~ "Imported-labour traffic: +3.0/tick"
    end

    # Finding 1: a treasury covering a per-tick deficit must not make the totals
    # cell contradict its own two halves. Money supplied 13, demanded 23, but a
    # treasury of 487 (carried) brings the balance-inclusive `satisfaction` to
    # 1.0 -- exactly the case that used to render "23/13 · 100.0%", where dividing
    # the two numbers shown gives 57%, not 100%. The cell must read the flow-only
    # figure instead, so 56.5% (13/23) is what belongs under 23/13.
    test "the money totals cell reads the flow-only percentage, not the balance-inclusive one",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:city_metrics, metrics_with_money_deficit_covered_by_treasury()})
      render(view)

      cell = view |> element(~s{[data-total="money"]}) |> render()
      assert cell =~ "23/13"
      assert cell =~ "56.5%"
      refute cell =~ "100.0%"
    end

    test "satisfaction appears only in the totals row, not in a Metrics list",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:city_metrics, metrics_with_distinct_satisfaction()})
      render(view)

      # Positive case: the Metrics block survived the move into the sidebar.
      assert has_element?(view, "#metrics-tick")

      # Water's satisfaction is the one figure only it has, and the totals row is where
      # it belongs.
      assert view |> element(~s{[data-total="water"]}) |> render() =~ "50.0%"

      # "Only" is a claim about how many times the figure is on the page, which no
      # single-element assertion can make — so count. Re-adding the old per-resource
      # list would render it a second time and split this into three parts.
      assert render(view) |> String.split("50.0%") |> length() == 2
    end

    test "a divergence too small to survive rounding is not shown as an arrow",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Health decays continuously, so actual capacity drifts below rated by fractions
      # of a unit long before it drifts by a whole one. Both figures render as 120, and
      # an arrow from a number to itself is noise.
      send(view.pid, {:city_metrics, metrics_with_power_capacity(120.0, 119.7)})
      render(view)

      cell = view |> element(~s{[data-cell="power_plant-power"]}) |> render()
      assert cell =~ "+120"
      refute cell =~ "→"
    end

    test "a divergence big enough to see is shown as rated → actual", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:city_metrics, metrics_with_power_capacity(120.0, 90.0)})
      render(view)

      assert view |> element(~s{[data-cell="power_plant-power"]}) |> render() =~
               "+120 → +90"
    end

    test "a resource with no statistics at all shows an em dash in the totals row",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # SummarizeCity always reports all eight, so this is the defensive branch. Power is
      # present to prove the row still renders figures either side of the gap.
      send(view.pid, {:city_metrics, metrics_with_only_power_statistics()})
      render(view)

      assert view |> element(~s{[data-total="power"]}) |> render() =~ "100.0%"
      assert view |> element(~s{[data-total="water"]}) |> render() =~ "—"
    end

    # Collapsing used to remove the rows entirely, which took the only block-type
    # selector with it — there is no *Place* button row any more, the row IS the
    # control. Collapsing now drops the resource detail and keeps the control.
    test "collapsing keeps the type rows, so a block type can still be chosen",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#toggle-legend-detail") |> render_click()

      assert has_element?(view, "#legend-row-industrial"),
             "collapsed must still offer the type rows"

      view |> element(~s{#legend-row-industrial button}) |> render_click()

      assert has_element?(view, ~s{#legend-row-industrial button[aria-pressed="true"]}),
             "selecting a type while collapsed must work"
    end

    # Each refutation below is against a selector that demonstrably exists in the
    # expanded state asserted first, so it can actually go red.
    test "collapsing drops the resource columns and totals but keeps the count",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s{[data-cell="power_plant-power"]})
      assert has_element?(view, "#legend-totals")

      view |> element("#toggle-legend-detail") |> render_click()

      refute has_element?(view, ~s{[data-cell="power_plant-power"]})
      refute has_element?(view, "#legend-totals")

      assert has_element?(view, ~s{[data-cell="power_plant-count"]}),
             "the count must survive collapsing"
    end

    test "the metrics stay visible whether the legend is expanded or collapsed",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#metrics-tick")

      view |> element("#toggle-legend-detail") |> render_click()

      assert has_element?(view, "#metrics-tick"), "metrics must never be hidden"
      assert has_element?(view, "#metrics-offline")
    end

    test "the metrics panel shows the treasury", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#metrics-treasury")

      # This suite intentionally seeds a grandfathered city with 500 so legend tests do
      # not depend on a player-facing issue choice.
      assert view |> element("#metrics-treasury") |> render() =~ "Treasury: 500"
    end

    test "the treasury line turns red only while the next tick depletes it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:city_metrics, %{empty_city_metrics() | treasury_delta: -0.5}})
      render(view)

      draining = view |> element("#metrics-treasury") |> render()
      assert draining =~ ~s(data-depleting="true")
      assert draining =~ "text-red-700"
      assert draining =~ "dark:text-red-300"

      send(view.pid, {:city_metrics, %{empty_city_metrics() | treasury_delta: 0.0}})
      render(view)

      steady = view |> element("#metrics-treasury") |> render()
      assert steady =~ ~s(data-depleting="false")
      refute steady =~ "text-red-700"
    end

    test "the metrics panel shows the landfill, floored", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:city_metrics, %{empty_city_metrics() | waste_stock: 78.6}})
      render(view)

      # `trunc`, matching the treasury line: 78.6 renders 78, never 79.
      assert view |> element("#metrics-landfill") |> render() =~ "78"
      refute view |> element("#metrics-landfill") |> render() =~ "79"

      # The label is a decision, so a rename should fail a test rather than pass.
      assert view |> element("#metrics-landfill") |> render() =~ "Landfill"
    end

    test "the metrics panel shows injury and disease stocks", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(
        view.pid,
        {:city_metrics, %{empty_city_metrics() | injury_stock: 7.5, disease_stock: 12.0}}
      )

      render(view)

      assert view |> element("#metrics-injuries") |> render() =~ "Injuries: 7.5"
      assert view |> element("#metrics-disease") |> render() =~ "Disease: 12.0"
    end

    test "the first injury explains traffic pressure and can be dismissed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      injured = %{empty_city_metrics() | injury_stock: 0.6}

      send(view.pid, {:city_metrics, injured})

      assert has_element?(view, "#opening-goal-banner[data-variant=health_tutorial]")
      assert has_element?(view, "#opening-goal", "Why injuries appeared")
      assert has_element?(view, "#opening-goal", "Traffic crossed its healthy threshold")
      assert has_element?(view, "#opening-goal", "Add transit capacity or reduce traffic")

      view |> element("#dismiss-health-tutorial") |> render_click()
      refute has_element?(view, "#opening-goal-banner[data-variant=health_tutorial]")

      send(view.pid, {:city_metrics, empty_city_metrics()})
      render(view)
      send(view.pid, {:city_metrics, injured})

      refute has_element?(view, "#opening-goal-banner[data-variant=health_tutorial]")
    end

    test "the first disease case explains outbreaks and treatment", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:city_metrics, %{empty_city_metrics() | disease_stock: 4.0}})

      assert has_element?(view, "#opening-goal-banner[data-variant=health_tutorial]")
      assert has_element?(view, "#opening-goal", "Why disease appeared")
      assert has_element?(view, "#opening-goal", "scheduled outbreak")
      assert has_element?(view, "#opening-goal", "healthy hospital treats ten disease cases")
    end

    test "an existing hospital suppresses the first health tutorial", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      metrics =
        empty_city_metrics()
        |> put_hospital_count(1)
        |> Map.put(:injury_stock, 0.6)

      send(view.pid, {:city_metrics, metrics})

      refute has_element?(view, "#opening-goal-banner[data-variant=health_tutorial]")
    end

    test "a negative satisfaction renders as 0%, not as a negative percentage",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:city_metrics, metrics_with_waste_backlog()})
      render(view)

      # Text only, not `render/1`'s raw HTML: the element's own id,
      # "metrics-tightest", contains a hyphen, so a `refute` against the tag's
      # markup would fail on the id attribute regardless of the percentage
      # inside it. `cost_text/2` below strips markup the same way, for the same
      # reason.
      tightest =
        view
        |> element("#metrics-tightest")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      # Positive case first: waste really is the tightest resource here, so this
      # is not a vacuous check on a line that never rendered.
      assert tightest =~ "waste"
      assert tightest =~ "0%"
      refute tightest =~ "-"
    end

    # Per-resource satisfaction otherwise lives only in the totals row, which
    # collapsing hides. This line is the one figure that has to survive, so it must
    # name the *lowest* resource rather than whichever the map yields first.
    test "the tightest line names the resource with the lowest satisfaction",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:city_metrics, metrics_with_distinct_satisfaction()})
      render(view)

      # power 100%, waste 75%, water 50%, traffic 25% — traffic is the answer.
      line = view |> element("#metrics-tightest") |> render()

      assert line =~ "traffic"
      assert line =~ "25"
      refute line =~ "power"
    end

    # A fresh city has every resource at 1.0, so the minimum is a four-way tie and
    # `min_by` breaks it arbitrarily — it read "Tightest: traffic 100%", which is true
    # and says nothing about traffic. The positive assertion above proves the line can
    # name a resource, so this refutation has a state in which it fails.
    # The outer flex row already makes the content-driven placement decision. Changing the
    # sidebar's inner layout after that decision feeds a new intrinsic width back into the
    # outer flex row, so the stable form is one fixed column with no placement observer.
    test "metrics layout has a stable footprint", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#legend-and-metrics.flex.flex-col")
      assert has_element?(view, "#metrics-panel.w-80.max-w-full.shrink-0")
      assert has_element?(view, "#metrics-market-slot.min-h-20")
      refute has_element?(view, "#sidebar-placement-observer")

      layout = view |> element("#legend-and-metrics") |> render()
      refute layout =~ "data-position"
      refute layout =~ "flex-row"
    end

    # `grow` on the aside let the sidebar stretch across the whole page whenever it was
    # alone on its flex line. It must remain content-sized in both positions; the matrix
    # independently overrides daisyUI's `width: 100%` with `w-fit`.
    test "the sidebar is never wider than its own content", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      aside = view |> element("aside") |> render()
      refute aside =~ ~r/<aside[^>]*class="[^"]*\bgrow\b/
    end

    test "no resource is singled out while everything is fully supplied", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      line = view |> element("#metrics-tightest") |> render()

      assert line =~ "All resources supplied"

      for resource <- Node.resources() do
        refute line =~ to_string(resource)
      end
    end

    # Separate from the collapse test above, which only ever asked whether the rows
    # were there. The button is the sole affordance for getting them back, and both
    # the label and `aria-expanded` were free to freeze in one state unnoticed: a
    # collapsed sidebar would sit there offering to hide something already hidden.
    test "the toggle names the action it will perform and reports its state",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s{#toggle-legend-detail[aria-expanded="true"]})
      assert view |> element("#toggle-legend-detail") |> render() =~ "Hide detail"

      view |> element("#toggle-legend-detail") |> render_click()

      assert has_element?(view, ~s{#toggle-legend-detail[aria-expanded="false"]})
      assert has_element?(view, ~s{#legend-panel[style="width: 384px;"]})
      assert view |> element("#toggle-legend-detail") |> render() =~ "Show detail"

      view |> element("#toggle-legend-detail") |> render_click()

      assert has_element?(view, ~s{#toggle-legend-detail[aria-expanded="true"]})
      assert has_element?(view, ~s{#legend-panel[style="width: 760px;"]})
      assert view |> element("#toggle-legend-detail") |> render() =~ "Hide detail"
    end

    # A 2x2 holds two nodes; this places three, so a fresh city would grow underneath it.
    @tag :roomy_city
    test "park's labour cell shows the amenity net of the park's own staffing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      place(view, :residential, 1, 1)
      place(view, :residential, 2, 1)
      place(view, :park, 3, 1)

      # 2 housing, 1 park is ratio 0.5, below the cap: one more park adds L*k = 5 labour
      # and draws 1 of its own.
      assert view |> element(~s{[data-cell="park-labour"]}) |> render() =~ "+4"

      assert view
             |> element(~s{#metrics-workforce [data-workforce-multiplier="parks"]})
             |> render() =~ "Parks ×1.5"

      for multiplier <- ~w(parks schools health) do
        assert has_element?(
                 view,
                 ~s{#metrics-workforce > p.pl-3[data-workforce-multiplier="#{multiplier}"]}
               )
      end
    end

    @tag :roomy_city
    test "school's labour cell shows its multiplier net of school staffing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      for x <- 1..4, do: place(view, :residential, x, 1)
      place(view, :school, 1, 2)

      # Four homes supply 20 labour. One school reaches the 0.25 ratio cap, adds five
      # gross workers, and consumes four itself, for a net +1.
      assert view |> element(~s{[data-cell="school-labour"]}) |> render() =~ "+1"

      assert view |> element(~s{[data-cell="school-labour"] .font-semibold}) |> render() =~
               "+1"

      assert view
             |> element(~s{#metrics-workforce [data-workforce-multiplier="schools"]})
             |> render() =~ "Schools ×1.25"
    end

    # ×1.5 does not pin the precision: `Float.round(1.5, 1)` and `Float.round(1.5, 2)` both
    # render "1.5", so the assertion above passes at either. A ratio that is not a tenth
    # discriminates them — 1 park to 3 housing is 1 + 1/3 = ×1.33 at two decimals and
    # ×1.3 at one.
    @tag :roomy_city
    test "the Workforce multiplier is rendered to two decimals", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      for x <- 1..3, do: place(view, :residential, x, 1)
      place(view, :park, 1, 2)

      assert view
             |> element(~s{#metrics-workforce [data-workforce-multiplier="parks"]})
             |> render() =~ "Parks ×1.33"
    end

    # The bold half of the cell, which is the figure a player's eye lands on. It answers a
    # different question from the marginal line above it — "what are the parks I have
    # already placed contributing" — and before `amenity_labour` existed it fell through
    # to the general `is_nil(produced)` branch and reported the pure staffing draw, wrong
    # by the entire amenity and wrong in sign.
    #
    # Targeted on `.font-semibold` rather than on the cell, because the cell's text
    # contains the marginal figure too and "+12" would happily match nothing while "+4"
    # matched the wrong line.
    @tag :roomy_city
    test "park's labour total reports the placed parks' amenity, net of their staffing",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      for x <- 1..4, do: place(view, :residential, x, 1)
      for x <- 1..3, do: place(view, :park, x, 2)

      # 4 housing, 3 parks is ratio 0.75, below the cap. Measured: labour supply is 35.0
      # with the parks and 20.0 without, so they contribute +15 gross, less the 3 labour
      # they draw between them.
      assert view |> element(~s{[data-cell="park-labour"] .font-semibold}) |> render() =~ "+12"
    end

    @tag :roomy_city
    test "at the cap park's labour total is bounded by the housing, not the park count",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      for x <- 1..2, do: place(view, :residential, x, 1)
      for x <- 1..3, do: place(view, :park, x, 2)

      # 2 housing, 3 parks is ratio 1.5, clamped to the cap of 1.0. Past the cap the
      # amenity is `L * k * housing`, not `L * k * parks`: measured, labour supply is 20.0
      # with the parks and 10.0 without, so +10 gross less the 3 they draw. The third park
      # is paying its staffing for nothing, and this figure is where that shows.
      assert view |> element(~s{[data-cell="park-labour"] .font-semibold}) |> render() =~ "+7"
    end

    @tag :roomy_city
    test "past parity park's labour cell goes negative", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      place(view, :residential, 1, 1)
      place(view, :park, 2, 1)
      place(view, :park, 3, 1)

      # 1 housing, 2 parks: already past the cap, so another park adds no amenity at
      # all and still draws its 1 labour. Over-provisioning costs rather than merely
      # failing to help.
      assert view |> element(~s{[data-cell="park-labour"]}) |> render() =~ "-1"
    end

    @tag :roomy_city
    test "staffed types other than park render through the ordinary load path", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      place(view, :transit_hub, 1, 1)
      place(view, :power_plant, 2, 1)

      assert view |> element(~s{[data-cell="transit_hub-labour"]}) |> render() =~ "-2"
      assert view |> element(~s{[data-cell="power_plant-labour"]}) |> render() =~ "-1"
      assert view |> element(~s{[data-cell="power_plant-money"]}) |> render() =~ "-5"
    end

    test "a type that does not touch a resource still renders an em dash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Positive case first, so this cannot pass against a page rendering em dashes
      # everywhere: power plants do draw water, and that cell is a real number.
      assert view |> element(~s{[data-cell="power_plant-water"]}) |> render() =~ "-20"

      # The park special case must not leak into the general path. Power plants now touch
      # every resource, so use transit, which neither consumes nor supplies water.
      assert view |> element(~s{[data-cell="transit_hub-water"]}) |> render() =~ "—"
    end

    test "every legend row shows its construction cost", %{conn: conn} do
      # Asserted on the cell's *text*, not on `render/1`'s HTML. The HTML includes the
      # `title` attribute added in this same step, whose value is "costs 80" — so
      # `render() =~ "80"` would pass even if the cell body rendered the count, or the
      # demolition cost, or nothing at all. An exact match on trimmed text can fail.
      {:ok, view, _html} = live(conn, ~p"/")

      assert cost_text(view, :power_plant) == "80"
      assert cost_text(view, :residential) == "15"
    end

    test "the cost column survives a collapse, unlike the resource columns", %{conn: conn} do
      # The type rows are the only way to choose what to place, and choosing now spends
      # money — so price cannot be detail-only.
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#toggle-legend-detail") |> render_click()

      assert has_element?(view, ~s{[data-cell="power_plant-cost"]})
      refute has_element?(view, ~s{[data-cell="power_plant-power"]})
    end

    @tag treasury: 40.0
    test "unaffordable rows are marked and dimmed, affordable ones are not", %{conn: conn} do
      # Both directions throughout: a hardcoded "false" would satisfy either alone. 40
      # sits between residential's 15 and power_plant's 80, so one row must come out each
      # way.
      #
      # 40.0 is load-bearing — do not "tidy" it. `commercial` and `transit_hub` cost
      # exactly 40, so this fixture is also the only thing pinning `affordable?/2`'s `>=`
      # against `>`. Under `>` those two rows would dim while
      # `ManageInfrastructure.place/4` (`money < cost` → `40.0 < 40.0` → false) built them
      # happily, which is exactly the disagreement the comment above `affordable?/2`
      # promises cannot happen. Only the `commercial` assertion can catch that mutation;
      # the power_plant and residential ones hold either way.
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s{#legend-row-power_plant[data-affordable="false"]})
      assert has_element?(view, ~s{#legend-row-residential[data-affordable="true"]})
      assert has_element?(view, ~s{#legend-row-commercial[data-affordable="true"]})

      # `data-affordable` is a test hook nobody looks at. These two are what a player
      # actually gets: the dim, and — since dimming is visual-only — the cost cell's
      # title carrying the same fact for anyone who cannot see it. Deleting either is
      # silent otherwise.
      assert has_element?(view, ~s{#legend-row-power_plant.opacity-40})
      refute has_element?(view, ~s{#legend-row-residential.opacity-40})

      assert has_element?(
               view,
               ~s{[data-cell="power_plant-cost"][title="costs 80 — more than the treasury holds"]}
             )

      assert has_element?(view, ~s{[data-cell="residential-cost"][title="costs 15"]})
    end

    # Waste and traffic are the columnar bads, so a block that removes them reads
    # negative and a block that emits them reads positive. Injuries and disease use
    # the hospital treatment summary tested above instead of sparse columns.
    test "a negative resource shows removal as negative and emission as positive",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Nothing placed, so these are the per-block marginal figures and the test
      # needs no treasury.
      assert view |> element(~s{[data-cell="industrial-waste"]}) |> render() =~ "-90"
      assert view |> element(~s{[data-cell="residential-waste"]}) |> render() =~ "+10"

      # Traffic is the second negative resource, and it is not a copy of waste in
      # the code — only in `@negative_resources`. Without these two lines, shipping
      # the list as `[:waste]` passes the whole suite.
      assert view |> element(~s{[data-cell="transit_hub-traffic"]}) |> render() =~ "-60"
      assert view |> element(~s{[data-cell="residential-traffic"]}) |> render() =~ "+6"

      # Positive resources in the same test. A flip applied to *every* resource rather
      # than the negative ones satisfies the four assertions above; these two are what
      # catch that broader mutation.
      assert view |> element(~s{[data-cell="power_plant-power"]}) |> render() =~ "+120"
      assert view |> element(~s{[data-cell="residential-power"]}) |> render() =~ "-15"
    end

    # Three houses at 15 each is 45, but the treasury is raised so the fixture does not
    # depend on any player-facing financing choice.
    @tag treasury: 1_000.0
    test "a negative resource's city total flips too, not only the per-block figure",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element(~s{button[phx-click="select_type"][phx-value-type="residential"]})
      |> render_click()

      for {x, y} <- [{1, 1}, {2, 1}, {3, 1}] do
        view
        |> element(~s{[phx-click="place"][phx-value-x="#{x}"][phx-value-y="#{y}"]})
        |> render_click()
      end

      # Asserted on `.font-semibold` — the total line's own class — and not on the
      # cell: the cell's text also holds the `+10` marginal, so a cell-level
      # assertion silently matches whichever of the two lines the flip reached.
      #
      # This exercises `total_cell/4`'s `is_nil(produced)` branch, which is the
      # branch that fires for every emitter, because no type both produces and
      # consumes waste. Flipping only the main branch leaves this reading `-30`.
      cell = view |> element(~s{[data-cell="residential-waste"] .font-semibold}) |> render()
      assert cell =~ "+30", "three houses must total +30 waste emitted"
    end

    test "a decaying remover shows its capacity failing, rated → actual", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:city_metrics, metrics_with_industrial_waste(90.0, 45.0)})
      render(view)

      # Both nets flip, not just the rated one. The mutation that flips `rated_net`
      # and leaves `actual_net` alone renders "-90 → +45", which an assertion on
      # either figure alone accepts.
      assert view |> element(~s{[data-cell="industrial-waste"] .font-semibold}) |> render() =~
               "-90 → -45"
    end
  end

  # Distinct values per resource on purpose: with every resource at 1.0 a test cannot
  # tell one totals cell from another, and "appears once" assertions become impossible.
  defp metrics_with_distinct_satisfaction do
    %{
      empty_city_metrics()
      | tick: 3,
        resources: %{
          power: stat(150.0, 120.0),
          water: stat(35.0, 70.0),
          waste: stat(60.0, 80.0),
          traffic: stat(25.0, 100.0)
        }
    }
  end

  # Only power, so `totals_cell/2` has to render the other five from nothing.
  defp metrics_with_only_power_statistics do
    %{empty_city_metrics() | resources: %{power: stat(150.0, 120.0)}}
  end

  # Money supplied 13, demanded 23, with a 487 treasury covering the 10 shortfall:
  # `satisfaction` (over supplied + carried, 500/23) is 1.0, `flow_satisfaction`
  # (over supplied alone, 13/23) is not. Built by hand, not via `stat/2`, because
  # `stat/2` always sets `carried: 0.0` and so cannot produce this divergence.
  defp metrics_with_money_deficit_covered_by_treasury do
    %{
      empty_city_metrics()
      | resources: %{
          money: %{
            supplied: 13.0,
            carried: 487.0,
            demanded: 23.0,
            deficit: 0.0,
            satisfaction: 1.0,
            flow_satisfaction: 13.0 / 23.0
          }
        }
    }
  end

  # Placing real nodes cannot produce an exact divergence — actual capacity is
  # whatever health decay happens to have left — so the breakdown is written directly.
  defp metrics_with_power_capacity(rated, actual) do
    metrics = empty_city_metrics()

    put_in(metrics.by_type[:power_plant], %{
      count: 1,
      rated_capacity: %{power: rated},
      actual_capacity: %{power: actual},
      load: %{water: 20.0, waste: 12.0, traffic: 3.0, labour: 1.0, money: 5.0}
    })
  end

  # The negative-resource counterpart to `metrics_with_power_capacity/2`. Industrial's
  # waste entry is *removal* capacity, and removal is health-scaled, so this is the
  # divergence a decaying incinerator actually produces. Written directly for the same
  # reason: placing real nodes cannot produce an exact rated/actual gap.
  defp metrics_with_industrial_waste(rated, actual) do
    metrics = empty_city_metrics()

    put_in(metrics.by_type[:industrial], %{
      count: 1,
      rated_capacity: %{waste: rated},
      actual_capacity: %{waste: actual},
      load: %{power: 40.0, water: 25.0, traffic: 8.0, labour: 12.0}
    })
  end

  defp empty_city_metrics do
    %{SimulationMetrics.build(legacy_city(40, 30), %{}) | bond: %{legacy: true}}
  end

  defp put_hospital_count(metrics, count) do
    hospital = metrics.by_type |> Map.fetch!(:hospital) |> Map.put(:count, count)
    %{metrics | by_type: Map.put(metrics.by_type, :hospital, hospital)}
  end

  # Waste supplied 40 against demand 50 with a 60 backlog: available -20 and
  # satisfaction -0.4, which renders -40% unclamped. Built by hand rather than
  # via `stat/2`, which always sets `carried: 0.0` and so cannot produce a
  # negative satisfaction at all.
  defp metrics_with_waste_backlog do
    %{
      empty_city_metrics()
      | waste_stock: 60.0,
        resources: %{
          waste: %{
            supplied: 40.0,
            carried: -60.0,
            demanded: 50.0,
            deficit: 70.0,
            satisfaction: -0.4,
            flow_satisfaction: 0.8
          }
        }
    }
  end

  # Supplied and demanded are distinct, and distinct per resource. The old fixture gave
  # 40.0/40.0 to everything, which renders as "40/40" — a cell that transposed the two
  # figures, or printed one of them twice, would have looked exactly the same.
  # `satisfaction` and `flow_satisfaction` are both derived from `supplied`/`demanded`
  # rather than passed in, and always agree here because `carried` is 0.0 — every
  # fixture built with this helper models a flow resource, not money, so the two
  # figures having no reason to diverge is the fixture matching reality, not a
  # guarantee the real shape still makes. (The real shape's two figures *can*
  # contradict `carried: 0.0`'s expectation — see the money-specific fixtures in
  # `simulation_calculator_test.exs` for the case where they diverge.)
  defp stat(supplied, demanded) do
    satisfaction = min(supplied / demanded, 1.0)

    %{
      supplied: supplied,
      carried: 0.0,
      demanded: demanded,
      deficit: max(demanded - supplied, 0.0),
      satisfaction: satisfaction,
      flow_satisfaction: satisfaction
    }
  end

  # The cost cell's *text*, with the markup and the attributes stripped off. The cell
  # carries a `title` that spells the same figure out in prose, so an assertion against
  # the rendered HTML cannot tell the price apart from its own tooltip.
  #
  # `LazyHTML` and not `Floki`: LiveView 1.2 dropped Floki for it, and `mix.exs` carries
  # `lazy_html` as the test-only HTML dependency. Floki is not available here at all.
  defp cost_text(view, type) do
    view
    |> element(~s{[data-cell="#{type}-cost"]})
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end
end
