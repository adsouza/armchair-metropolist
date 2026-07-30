defmodule ArmchairMetropolist.Infrastructure.Desktop.LogNotifier do
  @moduledoc """
  Adapter implementing the Notifier port by writing to the application log.

  The default notifier: it always succeeds and needs no desktop integration, so
  the engine can raise alerts on any target. A native desktop adapter can
  replace it through the `:notifier` config key without the engine changing.

  Notifications are logged at `:warning` — every notification the engine sends
  describes a condition the operator is expected to act on.
  """

  @behaviour ArmchairMetropolist.Domain.Ports.Notifier

  require Logger

  @impl true
  def notify(title, body) do
    Logger.warning("[city notification] #{title}: #{body}")
    :ok
  end
end
