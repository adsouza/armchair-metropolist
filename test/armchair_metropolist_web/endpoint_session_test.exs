defmodule ArmchairMetropolistWeb.EndpointSessionTest do
  @moduledoc """
  The session cookie's `secure` flag, asserted through a real request.

  Why through a request rather than against the options list: the options reach
  `Plug.Session` through the endpoint's plug pipeline, which in some `:plug_init_mode`
  settings resolves them at *compile* time. A test that only read the options list
  would pass while the pipeline kept serving a stale, baked-in copy — the exact
  failure this file exists to catch.

  What it is defending against: a `secure` cookie is refused outright by a webview on
  a plain-HTTP origin, and the desktop target serves `http://127.0.0.1` by design. The
  cookie then never comes back, so the LiveView socket's `connect_info` carries no
  session, `Phoenix.LiveView.Channel` logs "LiveView session was misconfigured or the
  user token is outdated" and replies `{:error, %{reason: "stale"}}`, and the client
  reloads in a loop. Nothing crashes; the window just never becomes interactive.

  `async: false`: mutates OS env.
  """
  use ArmchairMetropolistWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias ArmchairMetropolist.Infrastructure.Simulation.CityRegistry

  @cookie_name "_armchair_metropolist_key"

  setup do
    saved = System.get_env("ARMCHAIR_DESKTOP")

    on_exit(fn ->
      if saved,
        do: System.put_env("ARMCHAIR_DESKTOP", saved),
        else: System.delete_env("ARMCHAIR_DESKTOP")
    end)

    # Each `get(conn, "/")` below dead-renders SimulatorLive, whose mount/3 opens a
    # city through the production `ensure_started/1` path — and EnsureCityId hands
    # every request its own fresh id, so every request leaks its own engine. Left
    # running they stay subscribed to the global "city_tick" topic and break the next
    # test that asserts nothing is running (`tick_server_test.exs` does). Same sweep,
    # and the same reason for it, as `simulator_live_test.exs`.
    on_exit(fn ->
      CityRegistry.Registry
      |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.each(fn {_city_id, pid} ->
        capture_log(fn -> DynamicSupervisor.terminate_child(CityRegistry.Supervisor, pid) end)
      end)
    end)

    :ok
  end

  # The attributes, exactly — not `=~ "secure"`, which the base64 cookie *value*
  # could satisfy by coincidence and which would also match nothing useful if the
  # attribute were renamed.
  defp session_cookie_attributes(conn) do
    conn
    |> Plug.Conn.get_resp_header("set-cookie")
    |> Enum.find(&String.starts_with?(&1, @cookie_name <> "="))
    |> case do
      nil -> flunk("no #{@cookie_name} cookie was set, so this test proves nothing")
      header -> header |> String.split(";") |> Enum.map(&String.trim/1) |> MapSet.new()
    end
  end

  test "the desktop target does not mark the session cookie secure", %{conn: conn} do
    System.put_env("ARMCHAIR_DESKTOP", "1")

    attributes = session_cookie_attributes(get(conn, ~p"/"))

    refute "secure" in attributes,
           "a secure cookie is discarded by the desktop webview on http://127.0.0.1, " <>
             "which costs the window its LiveView session entirely"
  end

  test "the server target still marks the session cookie secure", %{conn: conn} do
    System.delete_env("ARMCHAIR_DESKTOP")

    attributes = session_cookie_attributes(get(conn, ~p"/"))

    assert "secure" in attributes,
           "the server is HTTPS-only via force_ssl; the cookie should not travel cleartext"
  end

  test "both targets keep the protections that are not scheme-dependent", %{conn: conn} do
    for marker <- [nil, "1"] do
      if marker,
        do: System.put_env("ARMCHAIR_DESKTOP", marker),
        else: System.delete_env("ARMCHAIR_DESKTOP")

      attributes = session_cookie_attributes(get(conn, ~p"/"))

      assert "HttpOnly" in attributes, "ARMCHAIR_DESKTOP=#{inspect(marker)}"
      assert "SameSite=Lax" in attributes, "ARMCHAIR_DESKTOP=#{inspect(marker)}"
      assert "max-age=#{90 * 24 * 60 * 60}" in attributes, "ARMCHAIR_DESKTOP=#{inspect(marker)}"
    end
  end
end
