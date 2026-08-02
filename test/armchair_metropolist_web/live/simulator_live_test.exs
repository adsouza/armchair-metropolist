defmodule ArmchairMetropolistWeb.SimulatorLiveTest do
  @moduledoc """
  LiveView tests for the city dashboard.

  `async: false`: the engine is a singleton registered under its module name
  and these tests inject application-env stub adapters, same as
  `city_engine_test.exs`. The test environment does not start the engine
  itself (`start_simulation: false` in `config/test.exs`, so it does not
  collide with `start_supervised!`/the Ecto sandbox), so each test starts its
  own `CityEngine` pointed at the in-memory `StubSnapshotRepository`.
  """
  use ArmchairMetropolistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Entities.Node
  alias ArmchairMetropolist.Domain.Entities.SimulationMetrics
  alias ArmchairMetropolist.Infrastructure.Simulation.CityEngine
  alias ArmchairMetropolist.StubSnapshotRepository

  setup do
    previous_repo = Application.get_env(:armchair_metropolist, :snapshot_repository)

    on_exit(fn ->
      case previous_repo do
        nil -> Application.delete_env(:armchair_metropolist, :snapshot_repository)
        value -> Application.put_env(:armchair_metropolist, :snapshot_repository, value)
      end
    end)

    Application.put_env(:armchair_metropolist, :snapshot_repository, StubSnapshotRepository)

    start_supervised!(StubSnapshotRepository)
    StubSnapshotRepository.set_initial({:error, :not_found})
    start_supervised!(CityEngine)

    :ok
  end

  test "renders the grid and the type picker", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Armchair Metropolist"
    assert html =~ "power_plant"
  end

  test "a delta broadcast updates only the affected node", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # Two nodes on the board, so "only" is actually testable. The old version of
    # this test placed one node and asserted it appeared, which the title
    # over-promised: it could not have detected the other one changing.
    for {x, y} <- [{4, 5}, {6, 7}] do
      Phoenix.PubSub.broadcast(
        ArmchairMetropolist.PubSub,
        "city_simulation",
        {:city_node_placed, Node.new(x, y, :power_plant)}
      )
    end

    untouched_before = rendered_node(render(view), "6:7")
    assert untouched_before =~ "bg-success"

    degraded = %Node{Node.new(4, 5, :power_plant) | health: 41.0, status: :degraded}

    Phoenix.PubSub.broadcast(
      ArmchairMetropolist.PubSub,
      "city_simulation",
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
      "city_simulation",
      {:city_node_placed, node}
    )

    # Prove the node is actually there before refuting its absence, otherwise
    # the refute below is vacuously true if the dom_id scheme ever drifts
    # from "x:y".
    assert render(view) =~ ~s{id="6:6"}

    Phoenix.PubSub.broadcast(
      ArmchairMetropolist.PubSub,
      "city_simulation",
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

  describe "legend" do
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

    test "a resource the type never touches shows an em dash, not a zero", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Positive case first: a road hub does consume power, so that cell holds a number.
      assert view |> element(~s{[data-cell="road_hub-power"]}) |> render() =~ "0"

      # It never touches water, and that must read differently from "nets to zero".
      water = view |> element(~s{[data-cell="road_hub-water"]}) |> render()
      assert water =~ "—"
      refute water =~ "0"
    end

    test "the totals row reports supply, demand and satisfaction per resource",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:city_metrics, metrics_with_distinct_satisfaction()})
      render(view)

      assert view |> element(~s{[data-total="power"]}) |> render() =~ "100.0%"
      assert view |> element(~s{[data-total="water"]}) |> render() =~ "50.0%"
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

      # SummarizeCity always reports all four, so this is the defensive branch. Power is
      # present to prove the row still renders figures either side of the gap.
      send(view.pid, {:city_metrics, metrics_with_only_power_statistics()})
      render(view)

      assert view |> element(~s{[data-total="power"]}) |> render() =~ "100.0%"
      assert view |> element(~s{[data-total="water"]}) |> render() =~ "—"
    end

    test "the sidebar starts expanded and can be collapsed and reopened", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#legend-row-power_plant"), "must start expanded"

      view |> element("#toggle-sidebar") |> render_click()
      refute has_element?(view, "#legend-row-power_plant")

      view |> element("#toggle-sidebar") |> render_click()
      assert has_element?(view, "#legend-row-power_plant"), "reopening must restore it"
    end
  end

  # Distinct values per resource on purpose: with every resource at 1.0 a test cannot
  # tell one totals cell from another, and "appears once" assertions become impossible.
  defp metrics_with_distinct_satisfaction do
    %{
      empty_city_metrics()
      | tick: 3,
        resources: %{
          power: stat(1.0),
          water: stat(0.5),
          waste: stat(0.75),
          traffic: stat(0.25)
        }
    }
  end

  # Only power, so `totals_cell/2` has to render the other three from nothing.
  defp metrics_with_only_power_statistics do
    %{empty_city_metrics() | resources: %{power: stat(1.0)}}
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

  defp stat(satisfaction) do
    %{supplied: 40.0, demanded: 40.0, deficit: 0.0, satisfaction: satisfaction}
  end
end
