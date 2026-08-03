defmodule ArmchairMetropolistWeb.CityControllerTest do
  @moduledoc """
  `async: false`, not the module's obvious default: the last test mounts
  SimulatorLive, whose `do_mount/2` calls `CityEngine.snapshot/1` unconditionally
  — even for a code nothing has visited before — so it needs the same
  `:snapshot_repository` override as `simulator_live_test.exs` and
  `content_security_policy_test.exs`, and that override is process-global.
  """
  use ArmchairMetropolistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ArmchairMetropolist.Infrastructure.Simulation.CityEngine
  alias ArmchairMetropolist.StubSnapshotRepository

  @valid "aaaaaaaaaaaaaaaaaaaaaa"

  # Must match `@legacy_city_id` in
  # priv/repo/migrations/20260803120000_city_scoped_snapshots.exs exactly: that
  # migration copies the deployed instance's one pre-existing city under this id so
  # it stays reachable at /c/<this>, and the whole point is that this route actually
  # adopts it. A drift between the two literals would make the preserved city
  # unreachable again with a green suite, which is exactly the failure Critical
  # finding 1 covers.
  @legacy_city_id "legacy0000000000000000"

  test "the migration's preserved legacy city is reachable and well-formed", %{conn: conn} do
    assert String.length(@legacy_city_id) == 22
    assert ArmchairMetropolistWeb.CityCode.valid?(@legacy_city_id)

    conn = get(conn, ~p"/c/#{@legacy_city_id}")

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :city_id) == @legacy_city_id
  end

  test "a valid code is adopted and redirects to the simulator", %{conn: conn} do
    conn = get(conn, ~p"/c/#{@valid}")

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :city_id) == @valid
  end

  test "a valid code replaces whatever the browser had", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{"city_id" => "bbbbbbbbbbbbbbbbbbbbbb"})
      |> get(~p"/c/#{@valid}")

    assert get_session(conn, :city_id) == @valid
  end

  test "a malformed code is a 404 and does not touch the session", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{"city_id" => "bbbbbbbbbbbbbbbbbbbbbb"})
      |> get(~p"/c/not-a-valid-code")

    assert conn.status == 404
    assert get_session(conn, :city_id) == "bbbbbbbbbbbbbbbbbbbbbb"
  end

  test "entering an unknown but well-formed code yields an empty city", %{conn: conn} do
    # Same scaffolding as simulator_live_test.exs's setup, inlined here because
    # only this test drives a LiveView: the real Ecto-backed adapter would hit
    # the database from the CityEngine process, which owns no sandbox
    # connection, and `start_supervised!/1` (rather than leaving `ensure_started/1`
    # to spin one up on demand) is what makes ExUnit tear this engine down when
    # the test ends instead of it lingering as an orphan for `engine_linger_ms`.
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
    start_supervised!({CityEngine, city_id: @valid})

    conn = get(conn, ~p"/c/#{@valid}")

    {:ok, _view, html} = conn |> recycle() |> live(~p"/")

    # The positive case, which the refute below needs in order to mean anything: the
    # code from the URL is what the mounted city is actually keyed by. Without this the
    # refute passes even if enter/2 discarded the code and mounted an unrelated city,
    # because the stub returns the same empty city for every id.
    assert html =~ @valid

    refute html =~ ~s{id="3:4"}
  end
end
