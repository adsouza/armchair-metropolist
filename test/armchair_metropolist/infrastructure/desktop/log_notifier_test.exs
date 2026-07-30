defmodule ArmchairMetropolist.Infrastructure.Desktop.LogNotifierTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ArmchairMetropolist.Infrastructure.Desktop.LogNotifier

  test "logs the title and body at :warning and returns :ok" do
    log =
      capture_log(fn ->
        assert LogNotifier.notify("Power deficit", "power at 18% of demand") == :ok
      end)

    assert log =~ "[warning]"
    assert log =~ "[city notification] Power deficit: power at 18% of demand"
  end
end
