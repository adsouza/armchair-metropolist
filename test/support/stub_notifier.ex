defmodule ArmchairMetropolist.StubNotifier do
  @moduledoc "Forwards notifications to the pid in :notifier_test_pid."

  # Test-support module, not shipped code: it lives outside the app's
  # boundary tree (only compiled for `elixirc_paths(:test)`), so it gets its
  # own top-level boundary with checks disabled rather than being folded
  # into any production boundary. See the boundary lib docs' "Ignoring
  # checks... useful for test support modules" guidance.
  use Boundary, top_level?: true, check: [in: false, out: false]

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
