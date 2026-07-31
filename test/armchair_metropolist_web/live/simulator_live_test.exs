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

  alias ArmchairMetropolist.Domain.Entities.Node
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
end
