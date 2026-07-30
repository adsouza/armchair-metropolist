defmodule ArmchairMetropolist.StubNotifier do
  @moduledoc "Forwards notifications to the pid in :notifier_test_pid."
  @behaviour ArmchairMetropolist.Domain.Ports.Notifier

  @impl true
  def notify(title, body) do
    case Application.get_env(:armchair_metropolist, :notifier_test_pid) do
      nil -> :ok
      pid -> send(pid, {:notified, title, body})
    end

    :ok
  end
end
