defmodule ArmchairMetropolist.Infrastructure.Desktop.TauriNotifier do
  @moduledoc """
  Adapter implementing the Notifier port with native OS notifications.

  Selected on the desktop target through the `:notifier` config key, replacing
  `LogNotifier` without the engine changing.

  ## Why `ExTauri.Desktop` and not `ExTauri.Notification`

  `ExTauri.Notification.send/4` needs a LiveView socket, and the Notifier port is
  deliberately socket-free: the engine raises alerts from a GenServer that has no
  idea whether anyone has a browser tab open. `ExTauri.Desktop.notify/2` sends the
  same Tauri notification command over the sidecar channel that carries the
  shutdown heartbeat, so it works from any process.

  ## Failure is never fatal

  A notification is an aside; the simulation is the point. Every failure mode is
  swallowed and logged, and `notify/2` always answers `:ok`:

    * The channel is only up while a Tauri window is attached, so `ExTauri.Desktop`
      answers `{:error, :not_connected}` (or `{:error, :not_running}`) under
      `mix phx.server`. That is the normal web-target case, not an error.
    * `ExTauri.Desktop.notify/2` is a `GenServer.call`, so a stalled or dying
      ShutdownManager would otherwise raise *in the engine's own process* and take
      the city down with it. Hence the `try`.

  The engine also logs `notifier().notify/2` errors, so returning `{:error, _}`
  here would produce noise on every tick of a deficit in the web target for a
  condition that is expected. Downgrading to a debug log is the point.
  """

  @behaviour ArmchairMetropolist.Domain.Ports.Notifier

  require Logger

  @impl true
  def notify(title, body) do
    case send_notification(title, body) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("native notification unavailable (#{inspect(reason)}): #{title}: #{body}")
        :ok
    end
  end

  defp send_notification(title, body) do
    case ExTauri.Desktop.notify(title, body: body) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
