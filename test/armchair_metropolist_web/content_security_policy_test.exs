defmodule ArmchairMetropolistWeb.ContentSecurityPolicyTest do
  @moduledoc """
  Pins the Content-Security-Policy, because nothing else would notice it changing.

  A CSP is invisible when correct and silent when weakened: dropping the nonce for
  `'unsafe-inline'`, or losing the header entirely, breaks nothing a user or any
  other test would see. Sobelow does not check it either — its `Config.CSP` check
  looks for a static map passed to `:put_secure_browser_headers` and cannot see a
  per-request policy, which is why it sits in `.sobelow-conf`'s `ignore`.

  `async: false` for the same reason as `simulator_live_test.exs`: rendering `/`
  mounts the LiveView, which reads whatever city id the session below carries and
  talks to `CityEngine` for it — a process the test environment does not start
  (`start_simulation: false`), so each test starts its own, pinned to
  `CityEngine.default_city_id/0` and pointed at the in-memory stub, and pins the
  session to that same id so the two agree.
  """
  use ArmchairMetropolistWeb.ConnCase, async: false

  alias ArmchairMetropolist.Infrastructure.Simulation.CityEngine
  alias ArmchairMetropolist.StubSnapshotRepository

  setup %{conn: conn} do
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
    start_supervised!({CityEngine, city_id: CityEngine.default_city_id()})

    # Every request here is a dead render (`get/2`, never `live/2`), so `connected?`
    # is always false and `do_mount/2` never reaches the `CityEngine.attach/2` call —
    # the engine it starts via `CityEngine.snapshot/1` gets no viewer to monitor, so the
    # freeze-after-linger machinery in city_engine.ex never arms and it would run
    # forever. Pinning the session to the same id `start_supervised!` above already
    # owns, rather than leaving EnsureCityId (router.ex) to hand this conn a fresh
    # random one, means this test's engine is the one ExUnit tears down for us.
    conn = Plug.Test.init_test_session(conn, %{"city_id" => CityEngine.default_city_id()})

    {:ok, conn: conn}
  end

  defp policy(conn) do
    [header] = get_resp_header(conn, "content-security-policy")
    header
  end

  test "the response carries a policy at all", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert [_policy] = get_resp_header(conn, "content-security-policy")
  end

  test "inline script is allowed only by nonce, never by 'unsafe-inline'", %{conn: conn} do
    conn = get(conn, ~p"/")
    policy = policy(conn)

    assert policy =~ ~r/script-src [^;]*'nonce-[A-Za-z0-9_-]+'/,
           "script-src must carry a nonce, or the root layout's theme script cannot run"

    [script_src] = Regex.run(~r/script-src [^;]*/, policy)

    refute script_src =~ "'unsafe-inline'",
           "'unsafe-inline' in script-src defeats the directive: it permits exactly " <>
             "the injected inline script that CSP exists to stop"
  end

  test "the nonce in the header is the one on the rendered script tag", %{conn: conn} do
    conn = get(conn, ~p"/")
    [_, nonce] = Regex.run(~r/'nonce-([A-Za-z0-9_-]+)'/, policy(conn))

    assert html_response(conn, 200) =~ ~s{<script nonce="#{nonce}">},
           "a nonce the page does not carry blocks the theme script instead of allowing it"
  end

  test "each response gets a fresh nonce", %{conn: conn} do
    # A nonce reused across responses is worth no more than 'unsafe-inline', since an
    # attacker who can read one page can then inline a script into another.
    first = Regex.run(~r/'nonce-([A-Za-z0-9_-]+)'/, policy(get(conn, ~p"/")))
    second = Regex.run(~r/'nonce-([A-Za-z0-9_-]+)'/, policy(get(conn, ~p"/")))

    assert first != second
  end

  test "the deliberate concessions and hard limits stay as decided", %{conn: conn} do
    policy = policy(conn |> get(~p"/"))

    # Deliberate: the grid positions every cell with an inline `style` attribute.
    # Recorded here so removing it is a decision rather than an accident.
    assert policy =~ "style-src 'self' 'unsafe-inline'"

    assert policy =~ "default-src 'self'"
    assert policy =~ "frame-ancestors 'none'"
    assert policy =~ "object-src 'none'"
    assert policy =~ "base-uri 'self'"

    # Same-origin only. The LiveView socket is same-origin; there is no CDN or
    # third-party endpoint to allow, and adding one should be a conscious change.
    assert policy =~ "connect-src 'self'"
  end
end
