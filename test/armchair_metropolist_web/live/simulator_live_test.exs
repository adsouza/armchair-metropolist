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

    node = %Node{Node.new(4, 5, :power_plant) | health: 41.0, status: :degraded}

    Phoenix.PubSub.broadcast(
      ArmchairMetropolist.PubSub,
      "city_simulation",
      {:city_delta, %{"4:5" => node}}
    )

    assert render(view) =~ "4:5"
  end

  test "clicking a cell places infrastructure", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element(~s{[phx-click="place"][phx-value-x="2"][phx-value-y="3"]})
    |> render_click()

    assert render(view) =~ "2:3"
  end

  test "a removal broadcast deletes the node from the stream", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    node = Node.new(6, 6, :park)

    Phoenix.PubSub.broadcast(
      ArmchairMetropolist.PubSub,
      "city_simulation",
      {:city_node_placed, node}
    )

    assert render(view) =~ "6:6"

    Phoenix.PubSub.broadcast(
      ArmchairMetropolist.PubSub,
      "city_simulation",
      {:city_node_removed, "6:6"}
    )

    refute render(view) =~ ~s{id="6:6"}
  end
end
