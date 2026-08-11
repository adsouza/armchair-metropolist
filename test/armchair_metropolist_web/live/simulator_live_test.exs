defmodule ArmchairMetropolistWeb.SimulatorLiveTest do
  use ArmchairMetropolistWeb.SimulatorLiveCase

  test "renders the grid and the legend", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Armchair Metropolist"
    assert html =~ "power_plant"

    # The old name promised a "type picker", a control this branch deleted; the grid
    # it also named went unasserted. Both halves of the name are now checked.
    assert has_element?(view, ~s{[phx-click="place"][phx-value-x="0"][phx-value-y="0"]})
    assert has_element?(view, "#legend-totals")
  end

  test "an unrecognised message is dropped rather than crashing the view", %{conn: conn} do
    # Regression: SimulatorLive had no catch-all handle_info/2, so any unmatched message
    # raised FunctionClauseError and killed the view. Concretely reachable in a
    # mixed-version deploy — this branch changed `:city_reset` from a bare atom to
    # `{:city_reset, city_map}`, so an old-version engine broadcasting the bare atom to a
    # new-version view would hit this exact gap. `:some_retired_message` stands in for
    # any such stale broadcast.
    {:ok, view, _html} = live(conn, ~p"/")

    Phoenix.PubSub.broadcast(ArmchairMetropolist.PubSub, @topic, :some_retired_message)

    assert render(view) =~ "Armchair Metropolist"
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
    assert untouched_before =~ "bg-success/30"
    assert untouched_before =~ "dark:bg-success/20"

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

  test "two visitors with different sessions get different cities", %{conn: conn} do
    a = Plug.Test.init_test_session(conn, %{"city_id" => "aaaaaaaaaaaaaaaaaaaaaa"})
    b = Plug.Test.init_test_session(conn, %{"city_id" => "bbbbbbbbbbbbbbbbbbbbbb"})

    {:ok, view_a, _html} = live(a, ~p"/")
    {:ok, view_b, _html} = live(b, ~p"/")

    render_click(view_a, "place", %{"x" => "1", "y" => "1"})

    # The positive case first, so the refute below cannot be vacuous.
    assert render(view_a) =~ ~s{id="1:1"}
    refute render(view_b) =~ ~s{id="1:1"}
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

    render_click(view, "place", %{"x" => "1", "y" => "1"})

    # The city actually mounted is the desktop one, not the session's - checked via
    # CityEngine directly rather than the rendered HTML, because @city_id is not
    # itself shown anywhere once the re-entry block (asserted absent below) is
    # hidden.
    assert {:ok, %{city_map: desktop_map}} = CityEngine.snapshot(desktop_city_id)
    assert CityMap.occupied?(desktop_map, 1, 1)

    assert {:ok, %{city_map: session_map}} = CityEngine.snapshot(session_city_id)
    refute CityMap.occupied?(session_map, 1, 1)

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
    |> element(~s{[phx-click="place"][phx-value-x="1"][phx-value-y="1"]})
    |> render_click()

    # Anchored on the streamed node's own id, not a bare "1:1" substring: the
    # background cell at that same coordinate carries no coordinate of its own since
    # tooltips dropped them, but a plain substring match would still be vacuous
    # against any other "1:1" the page might contain.
    assert render(view) =~ ~s{id="1:1"}
  end

  @tag :roomy_city
  test "placed blocks use a distinct emoji for every block type", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    for {{type, _emoji}, x} <- Enum.with_index(@block_emojis) do
      send(view.pid, {:city_node_placed, Node.new(x, 0, type)})
    end

    render(view)

    for {{_type, emoji}, x} <- Enum.with_index(@block_emojis) do
      text =
        view
        |> element(~s{[id="#{x}:0"]})
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
        |> String.trim()

      assert text == emoji
    end
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
    |> element(~s{[phx-click="place"][phx-value-x="1"][phx-value-y="1"]})
    |> render_click()

    html = render(view)
    assert html =~ ~s{id="1:1"}

    # Scoped to the placed node's own markup via `rendered_node/2` rather than a bare
    # `title="..."` regex over the whole page: tooltips no longer carry a coordinate
    # (see SimulatorLive's node title comment), so nothing anchors a page-wide match to
    # this particular node. The *type* is what this test is about, so match the parts
    # that carry meaning and not the tooltip's punctuation: it also names the demolish
    # action and shows a health percentage, neither of which this test has any opinion
    # about.
    assert rendered_node(html, "1:1") =~ ~r/title="[^"]*park[^"]*online/
  end

  @tag :roomy_city
  test "four homes unlock tourism and a matched pair reports visitors, traffic, and revenue",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             ~s{#legend-row-entertainment[data-unlocked="false"] button[disabled]}
           )

    assert has_element?(view, ~s{#legend-row-hotel[data-unlocked="false"] button[disabled]})

    assert has_element?(
             view,
             "#city-column > #city-grid + #city-advisories > #tourism-unlock-banner"
           )

    refute has_element?(view, "#metrics-tourism")

    view
    |> element(~s{[phx-click="select_type"][phx-value-type="residential"]})
    |> render_click()

    for x <- 0..3 do
      view
      |> element(~s{[phx-click="place"][phx-value-x="#{x}"][phx-value-y="0"]})
      |> render_click()
    end

    assert has_element?(
             view,
             ~s{#legend-row-entertainment[data-unlocked="true"] button:not([disabled])}
           )

    assert has_element?(view, ~s{#legend-row-hotel[data-unlocked="true"] button:not([disabled])})
    refute has_element?(view, "#tourism-unlock-banner")
    assert has_element?(view, ~s{#metrics-tourism[data-unlocked="true"]})

    view
    |> element(~s{[phx-click="select_type"][phx-value-type="entertainment"]})
    |> render_click()

    view
    |> element(~s{[phx-click="place"][phx-value-x="4"][phx-value-y="0"]})
    |> render_click()

    view
    |> element(~s{[phx-click="select_type"][phx-value-type="hotel"]})
    |> render_click()

    view
    |> element(~s{[phx-click="place"][phx-value-x="5"][phx-value-y="0"]})
    |> render_click()

    assert view |> element("#metrics-tourists") |> render() =~ "12.0/tick"
    assert view |> element("#metrics-tourist-traffic") |> render() =~ "+12.0"
    assert view |> element("#metrics-tourist-revenue") |> render() =~ "+60.0"

    view |> element("#reset-city") |> render_click()
    view |> element("#confirm-reset") |> render_click()

    assert has_element?(view, "#bond-issuance")
    view |> element("#issue-bond-400") |> render_click()

    assert has_element?(view, "#opening-goal-banner")
    refute has_element?(view, "#tourism-unlock-banner")
    refute has_element?(view, "#metrics-tourism")
    assert has_element?(view, ~s{#legend-row-entertainment button[disabled]})
    assert has_element?(view, ~s{#legend-row-power_plant button[aria-pressed="true"]})
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

  test "successful city changes push matching sound cues", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    node = Node.new(6, 6, :park)

    send(view.pid, {:city_node_placed, node})
    assert_push_event view, "game-sound", %{cue: "build"}

    send(view.pid, {:city_node_removed, node.id})
    assert_push_event view, "game-sound", %{cue: "demolish"}
  end

  test "clicking demolish on a placed node removes it from the stream", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element(~s{[phx-click="place"][phx-value-x="1"][phx-value-y="1"]})
    |> render_click()

    # Same vacuity concern as the PubSub removal test: prove the node
    # actually rendered before asserting it is gone after the demolish click.
    assert render(view) =~ ~s{id="1:1"}

    view
    |> element(~s{[phx-click="demolish"][phx-value-x="1"][phx-value-y="1"]})
    |> render_click()

    refute render(view) =~ ~s{id="1:1"}
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

  test "the treasury is the final ordinary metric", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#metrics-tightest ~ #metrics-treasury + #metrics-market-slot")
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
    # flashes on every click. No tag: the grandfathered fixture covers an 80 plant.
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
    test "includes persistent music, sound-effects, and volume controls", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(
               view,
               "#game-audio-controls[phx-hook=GameAudio][phx-update=ignore][data-audio-state=on]"
             )

      assert has_element?(view, "#game-audio-toggle [data-audio-on]")
      assert has_element?(view, "#game-audio-toggle [data-audio-off].hidden")

      assert has_element?(
               view,
               "#game-volume-menu-toggle[aria-controls=game-volume-panel][aria-expanded=false]"
             )

      assert has_element?(view, "#game-volume-panel.hidden")

      assert has_element?(
               view,
               ~s{#game-volume-slider[type=range][min="10"][max="100"][step="1"][value="65"]}
             )
    end

    test "includes desktop-only explicit zoom controls", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(
               view,
               "#desktop-zoom-controls.hidden[phx-hook=DesktopZoom][phx-update=ignore]"
             )

      assert has_element?(view, "#desktop-zoom-out[data-zoom-action=out]")
      assert has_element?(view, "#desktop-zoom-reset[data-zoom-action=reset]", "100%")
      assert has_element?(view, "#desktop-zoom-in[data-zoom-action=in]")
    end

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
end
