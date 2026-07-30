defmodule ArmchairMetropolist.Domain.Ports.Notifier do
  @moduledoc "Output port for user-facing notifications."

  @callback notify(String.t(), String.t()) :: :ok | {:error, term()}
end
