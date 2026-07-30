defmodule ArmchairMetropolist.Infrastructure.Desktop.TauriNotifierTest do
  @moduledoc """
  `ExTauri.ShutdownManager` is only started under the desktop target
  (`start_shutdown_manager: true` in `config/runtime.exs`, gated off in
  `config/test.exs`), so the channel `ExTauri.Desktop.notify/2` depends on is
  never up by default in this suite. That is exactly the "no Tauri window
  attached" case the adapter must degrade gracefully under, so no mocking is
  needed to reach it - it is the natural state of the test environment.

  The success and "the channel misbehaves" branches, on the other hand, need
  something registered as `ExTauri.ShutdownManager` to answer the
  `GenServer.call/2` that `ExTauri.Desktop.notify/2` makes, so this suite
  stands up a tiny fake for those - hence `async: false`, since the name is
  a shared, global registration.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ArmchairMetropolist.Infrastructure.Desktop.TauriNotifier

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)
  end

  test "a notification failure never crashes the caller: notify/2 always returns :ok" do
    refute Process.whereis(ExTauri.ShutdownManager),
           "this test is only meaningful without a live Tauri channel"

    log =
      capture_log(fn ->
        assert TauriNotifier.notify("Power deficit", "power at 18% of demand") == :ok
      end)

    assert log =~ "native notification unavailable"
    assert log =~ "Power deficit: power at 18% of demand"
  end

  test "returns :ok with no logging when the Tauri channel accepts the notification" do
    start_fake_shutdown_manager(fn _request -> :ok end)

    log =
      capture_log(fn ->
        assert TauriNotifier.notify("Power deficit", "power at 18% of demand") == :ok
      end)

    assert log == ""
  end

  test "still returns :ok if the channel answers with something other than :ok/:error" do
    start_fake_shutdown_manager(fn _request -> {:surprising, :reply} end)

    log =
      capture_log(fn ->
        assert TauriNotifier.notify("Power deficit", "power at 18% of demand") == :ok
      end)

    assert log =~ "native notification unavailable"
  end

  test "still returns :ok if the channel crashes mid-call" do
    start_fake_shutdown_manager(fn _request -> raise "sidecar exploded" end)

    log =
      capture_log(fn ->
        assert TauriNotifier.notify("Power deficit", "power at 18% of demand") == :ok
      end)

    assert log =~ "native notification unavailable"
  end

  # A minimal stand-in for ExTauri.ShutdownManager, registered under its name so
  # ExTauri.Desktop's `Process.whereis(ShutdownManager)` finds it and routes the
  # `GenServer.call/2` here. `handler` decides the reply (or crashes the fake
  # process, to exercise TauriNotifier's `catch`).
  defp start_fake_shutdown_manager(handler) do
    {:ok, pid} =
      GenServer.start(
        __MODULE__.Fake,
        handler,
        name: ExTauri.ShutdownManager
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    pid
  end

  defmodule Fake do
    @moduledoc false
    use GenServer

    @impl true
    def init(handler), do: {:ok, handler}

    @impl true
    def handle_call(request, _from, handler), do: {:reply, handler.(request), handler}
  end
end
