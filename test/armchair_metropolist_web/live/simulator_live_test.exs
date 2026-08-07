defmodule ArmchairMetropolistWeb.SimulatorLiveTest do
  @moduledoc """
  LiveView tests for the city dashboard.

  `async: false`: these tests inject application-env stub adapters, same as
  `city_engine_test.exs`, which is process-global. The test environment does not
  start the engine itself (`start_simulation: false` in `config/test.exs`, so it
  does not collide with `start_supervised!`/the Ecto sandbox), so each test starts
  its own `CityEngine` pointed at the in-memory `StubSnapshotRepository`, addressed
  at `CityEngine.default_city_id/0` — a stable constant with no production reader,
  kept only so a test can pin one value in one place. `mount/3` itself reads the
  session, so this same value is written into `conn`'s session below; the view and
  the test agree on which city they are looking at because both were told to, not
  because `mount/3` derives it from this constant itself.
  """
  use ArmchairMetropolistWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Entities.Node
  alias ArmchairMetropolist.Domain.Entities.SimulationMetrics
  alias ArmchairMetropolist.Infrastructure.Simulation.CityEngine
  alias ArmchairMetropolist.Infrastructure.Simulation.CityRegistry
  alias ArmchairMetropolist.StubSnapshotRepository

  # The topic for the city id this test's session (below) pins the view to —
  # broadcasting on the old hardcoded "city_simulation" would silently miss the view.
  @topic CityEngine.topic(CityEngine.default_city_id())

  setup %{conn: conn} = context do
    previous_repo = Application.get_env(:armchair_metropolist, :snapshot_repository)

    on_exit(fn ->
      case previous_repo do
        nil -> Application.delete_env(:armchair_metropolist, :snapshot_repository)
        value -> Application.put_env(:armchair_metropolist, :snapshot_repository, value)
      end
    end)

    Application.put_env(:armchair_metropolist, :snapshot_repository, StubSnapshotRepository)

    start_supervised!(StubSnapshotRepository)
    StubSnapshotRepository.set_initial(initial_snapshot(context))
    start_supervised!({CityEngine, city_id: CityEngine.default_city_id()})

    # Every test but the two-visitor one below shares this session's city id with
    # `start_supervised!`'s engine above, exactly as a single shared deployment did
    # before Task 4. Without this, EnsureCityId (router.ex) would hand each `conn` its
    # own random id, mount/3 would open an engine the DynamicSupervisor owns instead of
    # this test's `start_supervised!`, and it would outlive the test that opened it.
    conn = Plug.Test.init_test_session(conn, %{"city_id" => CityEngine.default_city_id()})

    # The two-visitor test below still mounts two more cities through the production
    # ensure_started/1 path rather than start_supervised!/1, so nothing but this stops
    # them. ExUnit tears down `start_supervised!`'s "default" engine above before
    # on_exit callbacks run, so anything this sweep finds is one of those two leaks —
    # left running, each would sit subscribed to the global "city_tick" topic for
    # engine_linger_ms (30s in prod, unset here) and could checkpoint into whatever
    # :snapshot_repository a later test configures. Same problem and same fix as
    # city_engine_test.exs's "freezing when the last viewer leaves" describe block.
    on_exit(fn ->
      CityRegistry.Registry
      |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.each(fn {_city_id, pid} ->
        capture_log(fn -> DynamicSupervisor.terminate_child(CityRegistry.Supervisor, pid) end)
      end)
    end)

    {:ok, conn: conn}
  end

  test "renders the grid and the legend", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Armchair Metropolist"
    assert html =~ "power_plant"

    # The old name promised a "type picker", a control this branch deleted; the grid
    # it also named went unasserted. Both halves of the name are now checked.
    assert has_element?(view, ~s{[phx-click="place"][phx-value-x="0"][phx-value-y="0"]})
    assert has_element?(view, "#legend-totals")
  end

  test "a delta broadcast updates only the affected node", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # Two nodes on the board, so "only" is actually testable. The old version of
    # this test placed one node and asserted it appeared, which the title
    # over-promised: it could not have detected the other one changing.
    for {x, y} <- [{4, 5}, {6, 7}] do
      Phoenix.PubSub.broadcast(
        ArmchairMetropolist.PubSub,
        @topic,
        {:city_node_placed, Node.new(x, y, :power_plant)}
      )
    end

    untouched_before = rendered_node(render(view), "6:7")
    assert untouched_before =~ "bg-success"

    degraded = %Node{Node.new(4, 5, :power_plant) | health: 41.0, status: :degraded}

    Phoenix.PubSub.broadcast(
      ArmchairMetropolist.PubSub,
      @topic,
      {:city_delta, %{"4:5" => degraded}}
    )

    html = render(view)

    assert rendered_node(html, "4:5") =~ "bg-warning", "the delta's node must re-render"

    assert rendered_node(html, "6:7") == untouched_before,
           "a node absent from the delta must be byte-identical afterwards"
  end

  # The markup for one streamed node, so a test can compare a single entry rather
  # than the whole page.
  defp rendered_node(html, dom_id) do
    [_, tail] = String.split(html, ~s{id="#{dom_id}"}, parts: 2)
    String.slice(tail, 0, 160)
  end

  # `@tag treasury: n` seeds the balance of the city this test's engine hydrates.
  # There is no other way to set it: the engine owns the money, the refusal is decided
  # against the engine's copy, and this file starts its engine in `setup` — before any
  # test body could seed anything. Untagged tests get `{:error, :not_found}` exactly as
  # before, so the engine builds a fresh `CityMap` and they see the opening grant.
  #
  # The city is seeded *empty*: only the balance is preloaded, so every node in every
  # test is still placed through the running engine.
  defp initial_snapshot(%{treasury: money}) do
    {:ok, {0, %{CityMap.new(40, 30) | money: money}}}
  end

  defp initial_snapshot(_context), do: {:error, :not_found}

  test "two visitors with different sessions get different cities", %{conn: conn} do
    a = Plug.Test.init_test_session(conn, %{"city_id" => "aaaaaaaaaaaaaaaaaaaaaa"})
    b = Plug.Test.init_test_session(conn, %{"city_id" => "bbbbbbbbbbbbbbbbbbbbbb"})

    {:ok, view_a, _html} = live(a, ~p"/")
    {:ok, view_b, _html} = live(b, ~p"/")

    render_click(view_a, "place", %{"x" => "3", "y" => "4"})

    # The positive case first, so the refute below cannot be vacuous.
    assert render(view_a) =~ ~s{id="3:4"}
    refute render(view_b) =~ ~s{id="3:4"}
  end

  test "a browser session is shown the whole address that re-enters its city",
       %{conn: conn} do
    html = render(elem(live(conn, ~p"/"), 1))

    city_id = CityEngine.default_city_id()

    # Both halves, because they fail for different reasons. The href is the promise
    # that the link goes somewhere real - /c/:code is the only route that accepts a
    # code, and it appears nowhere else on the page. The visible text is the promise
    # that a player can *act* on it from another browser, which a bare code or a
    # relative path cannot deliver: there is nothing on screen telling them the host.
    assert html =~ ~s{href="/c/#{city_id}"}
    assert html =~ "#{ArmchairMetropolistWeb.Endpoint.url()}/c/#{city_id}"
  end

  test "the desktop target uses its configured city id and hides the re-entry code",
       %{conn: conn} do
    # Regression for Important finding 6: :desktop_city_id used to be read only from
    # mount/3's session-less fallback clause, which the desktop's own requests never
    # reached - the desktop window's page load goes through the same :browser
    # pipeline as a server request, so EnsureCityId always populates a session, and
    # the session-first clause always matched instead. Checked *before* the session
    # is what makes the pin real.
    desktop_city_id = "desktopdesktopdesktopd"
    previous = Application.get_env(:armchair_metropolist, :desktop_city_id)
    on_exit(fn -> Application.put_env(:armchair_metropolist, :desktop_city_id, previous) end)
    Application.put_env(:armchair_metropolist, :desktop_city_id, desktop_city_id)

    # A session carrying a *different* city id, as any ordinary browser request
    # would present - proving the desktop id wins over it, not merely that it works
    # when there is nothing to conflict with.
    session_city_id = "aaaaaaaaaaaaaaaaaaaaaa"
    conn = Plug.Test.init_test_session(conn, %{"city_id" => session_city_id})

    {:ok, view, _html} = live(conn, ~p"/")

    render_click(view, "place", %{"x" => "3", "y" => "4"})

    # The city actually mounted is the desktop one, not the session's - checked via
    # CityEngine directly rather than the rendered HTML, because @city_id is not
    # itself shown anywhere once the re-entry block (asserted absent below) is
    # hidden.
    assert {:ok, %{city_map: desktop_map}} = CityEngine.snapshot(desktop_city_id)
    assert CityMap.occupied?(desktop_map, 3, 4)

    assert {:ok, %{city_map: session_map}} = CityEngine.snapshot(session_city_id)
    refute CityMap.occupied?(session_map, 3, 4)

    # The desktop UI has no "elsewhere" to return to a code from, and the id is a
    # fixed constant rather than something worth revealing - so this block must not
    # render at all, not merely render a value nobody asked for.
    #
    # Anchored on the link's href, not on the sentence beside it. The copy is the
    # part of this block most likely to be reworded, and a refute against a string
    # that has been edited out of the codebase entirely passes for the wrong reason -
    # it would still be green with the block rendering in full. The test above
    # asserts this same href is present for a browser session, so the two move
    # together.
    refute render(view) =~ ~s{href="/c/}
  end

  test "clicking a cell places infrastructure", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element(~s{[phx-click="place"][phx-value-x="2"][phx-value-y="3"]})
    |> render_click()

    assert render(view) =~ "2:3"
  end

  test "selecting a type changes what placing a cell creates", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # power_plant is List.first(Node.types()) and is therefore already
    # selected on mount, so switching to :park is the change under test - if
    # "select_type" merely failed to crash without actually updating
    # @selected_type, the placed node would still come out as power_plant.
    view
    |> element(~s{[phx-click="select_type"][phx-value-type="park"]})
    |> render_click()

    view
    |> element(~s{[phx-click="place"][phx-value-x="9"][phx-value-y="9"]})
    |> render_click()

    html = render(view)
    assert html =~ ~s{id="9:9"}

    # The *type* is what this test is about, so match the parts that carry meaning and
    # not the tooltip's punctuation: it also names the demolish action and shows a health
    # percentage, neither of which this test has any opinion about.
    assert html =~ ~r/title="9:9[^"]*park[^"]*online/
  end

  test "a removal broadcast deletes the node from the stream", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    node = Node.new(6, 6, :park)

    Phoenix.PubSub.broadcast(
      ArmchairMetropolist.PubSub,
      @topic,
      {:city_node_placed, node}
    )

    # Prove the node is actually there before refuting its absence, otherwise
    # the refute below is vacuously true if the dom_id scheme ever drifts
    # from "x:y".
    assert render(view) =~ ~s{id="6:6"}

    Phoenix.PubSub.broadcast(
      ArmchairMetropolist.PubSub,
      @topic,
      {:city_node_removed, "6:6"}
    )

    refute render(view) =~ ~s{id="6:6"}
  end

  test "clicking demolish on a placed node removes it from the stream", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element(~s{[phx-click="place"][phx-value-x="7"][phx-value-y="8"]})
    |> render_click()

    # Same vacuity concern as the PubSub removal test: prove the node
    # actually rendered before asserting it is gone after the demolish click.
    assert render(view) =~ ~s{id="7:8"}

    view
    |> element(~s{[phx-click="demolish"][phx-value-x="7"][phx-value-y="8"]})
    |> render_click()

    refute render(view) =~ ~s{id="7:8"}
  end

  @tag treasury: 79.6
  test "the treasury renders floored, not rounded", %{conn: conn} do
    # 79.6 rounding to 80 while an 80-cost build is refused is a cell contradicting
    # itself. Both halves asserted together, because the defect is precisely the two
    # disagreeing — and 79.6 is chosen so they *can* disagree: at a whole number
    # `trunc` and `round` return the same thing and the test could not fail.
    {:ok, view, _html} = live(conn, ~p"/")

    assert view |> element("#metrics-treasury") |> render() =~ "79"
    refute view |> element("#metrics-treasury") |> render() =~ "80"
  end

  @tag treasury: 39.6
  test "a refused build flashes the cost and the balance", %{conn: conn} do
    # 39.6 rather than 40.0 for the same reason as above: the flash floors the balance
    # too, and a whole-number fixture could not tell `trunc` from `round`.
    {:ok, view, _html} = live(conn, ~p"/")

    html = place(view, :power_plant, 1, 1)

    assert html =~ "Not enough money"
    assert html =~ "power_plant costs 80"
    assert html =~ "treasury holds 39"
  end

  test "an affordable build flashes nothing", %{conn: conn} do
    # The positive case. Without it, the assertions above pass against a page that
    # flashes on every click. No tag: the untouched 150 grant covers an 80 plant.
    {:ok, view, _html} = live(conn, ~p"/")

    refute place(view, :power_plant, 1, 1) =~ "Not enough money"
  end

  @tag treasury: 24.6
  test "a refused demolition flashes the demolition cost", %{conn: conn} do
    # Seeded at 24.6 and then spent down *by playing*: a park costs 20, leaving 4.6, which
    # is below the flat 10 demolition fee. No mid-test balance setter needed, and the
    # path is one a player can actually walk.
    #
    # .6 rather than .0 for the same reason as the other two fixtures above: 4.6 is what
    # lets this test tell `unaffordable_demolition/1`'s own flooring apart from rounding —
    # `trunc` 4, `round` 5 — where a whole-number balance could not, since `trunc` and
    # `round` agree on every whole number.
    {:ok, view, _html} = live(conn, ~p"/")
    place(view, :park, 2, 2)

    html =
      view
      |> element(~s{[phx-click="demolish"][phx-value-x="2"][phx-value-y="2"]})
      |> render_click()

    assert html =~ "demolishing costs 10"
    assert html =~ "treasury holds 4"
  end

  describe "the page header" do
    test "lays its action group out as a row", %{conn: conn} do
      # daisyUI's `.flex-none` is `flex: none` — an *item* property, not `display: flex`.
      # With the original markup a button added to that group stacks above the theme
      # toggle instead of beside it. No content assertion can see that: the button is
      # present, labelled and clickable either way. Only this class can.
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(class="flex flex-none items-center gap-2")
    end

    test "gives the subtitle its own full-width row, right-aligned", %{conn: conn} do
      # `text-align` aligns to the column box, not to the text in it. With a `1fr`
      # column that box is wider than the wrapped title, which pushed the subtitle 64px
      # past it; `min-content` makes box and ink coincide. Also invisible to content
      # assertions — every rendered character is identical either way.
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "grid-cols-[auto_min-content]"
      assert html =~ ~s(class="col-span-2 text-right text-[11px] opacity-60")
    end
  end

  describe "legend" do
    # Two power plants at 80 each is 160, past the 150 opening grant. The type is not
    # negotiable for this block: the `+120` and `+360` figures two of these tests pin are
    # power_plant production, so switching to a cheaper type would turn a fixture fix into
    # a rebalance of the test's own subject. A round balance rather than 160 exactly, so a
    # change to the construction cost does not break a test that has no opinion about it.
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

      view |> element(~s{[phx-click="place"][phx-value-x="3"][phx-value-y="3"]}) |> render_click()

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

    # Three power plants at 80 each is 240, past the 150 opening grant.
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

    test "the totals row reports supply, demand and satisfaction per resource",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:city_metrics, metrics_with_distinct_satisfaction()})
      render(view)

      # Supply and demand are half the cell and were asserted nowhere: the whole
      # "supplied/demanded · " prefix could be deleted and the suite stayed green.
      # The fixture's two figures differ, and differ per resource, so a transposed
      # pair reads as wrong rather than as itself.
      assert view |> element(~s{[data-total="power"]}) |> render() =~ "150/120"
      assert view |> element(~s{[data-total="water"]}) |> render() =~ "35/70"

      assert view |> element(~s{[data-total="power"]}) |> render() =~ "100.0%"
      assert view |> element(~s{[data-total="water"]}) |> render() =~ "50.0%"
    end

    # Finding 1: a treasury covering a per-tick deficit must not make the totals
    # cell contradict its own two halves. Money supplied 13, demanded 23, but a
    # treasury of 487 (carried) brings the balance-inclusive `satisfaction` to
    # 1.0 -- exactly the case that used to render "13/23 · 100.0%", where dividing
    # the two numbers shown gives 57%, not 100%. The cell must read the flow-only
    # figure instead, so 56.5% (13/23) is what belongs beside 13/23.
    test "the money totals cell reads the flow-only percentage, not the balance-inclusive one",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:city_metrics, metrics_with_money_deficit_covered_by_treasury()})
      render(view)

      cell = view |> element(~s{[data-total="money"]}) |> render()
      assert cell =~ "13/23"
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

      # Health decays continuously, so actual production drifts below rated by fractions
      # of a unit long before it drifts by a whole one. Both figures render as 120, and
      # an arrow from a number to itself is noise.
      send(view.pid, {:city_metrics, metrics_with_power_production(120.0, 119.7)})
      render(view)

      cell = view |> element(~s{[data-cell="power_plant-power"]}) |> render()
      assert cell =~ "+120"
      refute cell =~ "→"
    end

    test "a divergence big enough to see is shown as rated → actual", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:city_metrics, metrics_with_power_production(120.0, 90.0)})
      render(view)

      assert view |> element(~s{[data-cell="power_plant-power"]}) |> render() =~
               "+120 → +90"
    end

    test "a resource with no statistics at all shows an em dash in the totals row",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # SummarizeCity always reports all six, so this is the defensive branch. Power is
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
      assert view |> element("#metrics-treasury") |> render() =~ "150"
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
    # Where Metrics sits relative to the legend is CSS, but *which* threshold governs it
    # is server-rendered, and it has to change with the state: the sidebar's width decides
    # where it wraps and collapsing changes that width. One constant for both is the bug
    # this pins — collapsing a wrapped legend moved it back beside the grid while Metrics
    # stayed alongside it.
    #
    # The values are midpoints of measured windows (expanded [2254, 2415], collapsed
    # [1415, 1415] — that one is degenerate, so it is the only legal value rather than a
    # midpoint with slack), not the wrap points themselves. See the comment in `render/1`:
    # an earlier pair sat on the windows' lower edges and fell out the moment the cells
    # grew a line. If a legitimate content change moves these, re-measure in the browser
    # and move them to the new *midpoint* — do not derive them from these plus a guess at
    # the width of whatever you added.
    test "the metrics wrap threshold follows the collapsed state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      expanded = view |> element(~s{aside div.flex}) |> render()
      assert expanded =~ "max-[2335px]:flex-row"
      refute expanded =~ "max-[1415px]:flex-row"

      view |> element("#toggle-legend-detail") |> render_click()

      collapsed = view |> element(~s{aside div.flex}) |> render()
      assert collapsed =~ "max-[1415px]:flex-row"
      refute collapsed =~ "max-[2335px]:flex-row"
    end

    # `grow` on the aside let daisyUI's `.table { width: 100% }` stretch the matrix across
    # the whole page whenever the sidebar was alone on its flex line. The sidebar must be
    # content-sized in both positions; that is what makes the table's `100%` a fixpoint.
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
      assert view |> element("#toggle-legend-detail") |> render() =~ "Show detail"

      view |> element("#toggle-legend-detail") |> render_click()

      assert has_element?(view, ~s{#toggle-legend-detail[aria-expanded="true"]})
      assert view |> element("#toggle-legend-detail") |> render() =~ "Hide detail"
    end

    test "park's labour cell shows the amenity net of the park's own staffing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      place(view, :residential, 1, 1)
      place(view, :residential, 2, 1)
      place(view, :park, 3, 1)

      # 2 housing, 1 park is ratio 0.5, below the cap: one more park adds L*k = 5 labour
      # and draws 1 of its own.
      assert view |> element(~s{[data-cell="park-labour"]}) |> render() =~ "+4"
      assert view |> element("#metrics-workforce") |> render() =~ "Workforce: ×1.5"
    end

    # ×1.5 does not pin the precision: `Float.round(1.5, 1)` and `Float.round(1.5, 2)` both
    # render "1.5", so the assertion above passes at either. A ratio that is not a tenth
    # discriminates them — 1 park to 3 housing is 1 + 1/3 = ×1.33 at two decimals and
    # ×1.3 at one.
    test "the Workforce multiplier is rendered to two decimals", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      for x <- 1..3, do: place(view, :residential, x, 1)
      place(view, :park, 1, 2)

      assert view |> element("#metrics-workforce") |> render() =~ "Workforce: ×1.33"
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

    test "staffed types other than park render through the ordinary consumption path", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      place(view, :transit_hub, 1, 1)
      place(view, :power_plant, 2, 1)

      assert view |> element(~s{[data-cell="transit_hub-labour"]}) |> render() =~ "-2"
      assert view |> element(~s{[data-cell="power_plant-labour"]}) |> render() =~ "-1"
    end

    test "a type that does not touch a resource still renders an em dash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Positive case first, so this cannot pass against a page rendering em dashes
      # everywhere: power plants do draw water, and that cell is a real number.
      assert view |> element(~s{[data-cell="power_plant-water"]}) |> render() =~ "-20"

      # The park special case must not leak into the general path. `power_plant` draws
      # labour now, so pick a genuinely untouched pair: it produces no money.
      assert view |> element(~s{[data-cell="power_plant-money"]}) |> render() =~ "—"
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

  # Placing real nodes cannot produce an exact divergence — actual production is
  # whatever health decay happens to have left — so the breakdown is written directly.
  defp metrics_with_power_production(rated, actual) do
    metrics = empty_city_metrics()

    put_in(metrics.by_type[:power_plant], %{
      count: 1,
      rated_production: %{power: rated},
      actual_production: %{power: actual},
      consumption: %{water: 20.0, waste: 12.0, traffic: 3.0}
    })
  end

  defp empty_city_metrics, do: SimulationMetrics.build(CityMap.new(40, 30), %{})

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

  # Selects the type once, then places it at one cell — the two-step gesture the UI
  # actually requires, wrapped so a test can name the type and the coordinate together.
  defp place(view, type, x, y) do
    view
    |> element(~s{button[phx-click="select_type"][phx-value-type="#{type}"]})
    |> render_click()

    view
    |> element(~s{[phx-click="place"][phx-value-x="#{x}"][phx-value-y="#{y}"]})
    |> render_click()
  end
end
