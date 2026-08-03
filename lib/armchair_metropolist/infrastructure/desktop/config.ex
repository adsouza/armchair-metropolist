defmodule ArmchairMetropolist.Infrastructure.Desktop.Config do
  @moduledoc """
  The desktop target's configuration, applied in code rather than from
  `config/runtime.exs`.

  ## Why this is not runtime.exs

  Not because config files fail to run in a packaged sidecar — they do, verified
  by setting a marker key in `config/runtime.exs` and reading it back inside the
  running Burrito binary. Two plainer reasons:

    * a config file is not reachable from a test, and every value set here is
      one that nothing else in the system would notice the loss of, which is
      exactly the kind that needs asserting (see the test for this module);

    * one definition cannot drift from itself. These settings previously existed
      in both places at once.

  Idempotent by construction: it only writes application env, so applying twice
  is harmless.

  ## The trap that made this look like a config problem

  For a long time none of the endpoint settings below appeared to take effect:
  the packaged app bound `0.0.0.0`, and origin checking stayed on so the window
  rejected its own LiveView socket. The cause was not configuration at all. A
  production Burrito binary unpacks its payload on first launch and then reuses
  that copy forever — the cache key is only `<name>_erts-<erts>_<app version>`,
  so with a fixed `version` in `mix.exs` every rebuild was a no-op at runtime and
  the sidecar kept executing the first build ever made, which predated this
  module. `mix.exs` now evicts that cache as the last release step; the long
  version of the story is in `evict_burrito_payload_cache/1`.

  Worth knowing if you ever debug this target again: `IO.puts` during
  `Application.start/2` does not reach the sidecar's stdout, though `Logger`
  does. An `IO.puts` probe here proves nothing either way.
  """

  @doc """
  True when the Tauri host marked this process as the desktop target.

  Set in `src-tauri/src/main.rs`, which injects `ARMCHAIR_DESKTOP=1` into the
  sidecar's environment. Absent for `mix phx.server`, `mix test` and the server
  release, all of which must keep the server configuration.
  """
  @spec desktop?() :: boolean()
  def desktop?, do: System.get_env("ARMCHAIR_DESKTOP") in ~w(1 true)

  @doc """
  Applies the desktop overrides to application env. No-op unless `desktop?/0`.
  """
  @spec apply!() :: :ok
  def apply! do
    if desktop?() do
      do_apply()
    else
      :ok
    end
  end

  defp do_apply do
    Application.put_env(:armchair_metropolist, :start_repo, false)
    Application.put_env(:armchair_metropolist, :start_shutdown_manager, true)

    # The desktop application has one city. Pinning the id here rather than relying
    # on the LiveView's fallback keeps the two targets' behaviour explicit, and means
    # a desktop build that somehow acquires a browser session still opens the same
    # city it always did.
    Application.put_env(:armchair_metropolist, :desktop_city_id, "desktop")

    Application.put_env(
      :armchair_metropolist,
      :snapshot_repository,
      ArmchairMetropolist.Infrastructure.Persistence.FileSnapshotStore
    )

    Application.put_env(
      :armchair_metropolist,
      :notifier,
      ArmchairMetropolist.Infrastructure.Desktop.TauriNotifier
    )

    Application.put_env(:armchair_metropolist, :snapshot_dir, snapshot_dir())

    endpoint = ArmchairMetropolistWeb.Endpoint
    existing = Application.get_env(:armchair_metropolist, endpoint, [])

    http =
      existing
      |> Keyword.get(:http, [])
      # Loopback only. A single-user desktop app has no reason to accept
      # connections from the local network, and binding loopback is what makes
      # `check_origin: false` below a safe trade rather than a hole.
      |> Keyword.put(:ip, {127, 0, 0, 1})
      |> Keyword.put(:port, port())
      # The snapshot-on-shutdown guarantee is on a stopwatch that is not ours.
      # Closing the window runs ExTauri's kill_sidecar: SIGTERM, poll 2s, SIGKILL.
      # Children stop in reverse order, so the Endpoint stops before the engine,
      # and Thousand Island's default 15s connection drain outlasts that budget —
      # the window's own LiveView socket is one of the connections being drained.
      # Measured: 8s to the snapshot write with the default, ~0.3s with this.
      |> Keyword.put(:thousand_island_options, shutdown_timeout: 100)

    Application.put_env(
      :armchair_metropolist,
      endpoint,
      existing
      |> Keyword.put(:http, http)
      |> Keyword.put(:url, host: "127.0.0.1", port: port(), scheme: "http")
      # Origin checking cannot be pinned when the Tauri host picks a fresh
      # ephemeral port per launch: there is no host:port pair to allowlist. Left
      # on, it rejected the LiveView socket on every launch and the UI rendered
      # and then sat on "attempting to reconnect".
      |> Keyword.put(:check_origin, false)
      |> Keyword.put(:server, true)
      |> Keyword.put(:secret_key_base, secret_key_base())
    )

    :ok
  end

  defp port do
    case Integer.parse(System.get_env("PORT") || "") do
      {port, ""} -> port
      _ -> raise "the desktop target expects PORT from the Tauri host"
    end
  end

  defp secret_key_base do
    System.get_env("SECRET_KEY_BASE") ||
      raise "the desktop target expects SECRET_KEY_BASE from the Tauri host"
  end

  # ExTauri.Paths.data_dir/0 creates the directory, so the file adapter's first
  # write always has somewhere to go. Resolved here rather than inside
  # FileSnapshotStore, which must stay free of any ExTauri reference.
  defp snapshot_dir, do: ExTauri.Paths.data_dir()
end
