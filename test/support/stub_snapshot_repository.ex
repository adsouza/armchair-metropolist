defmodule ArmchairMetropolist.StubSnapshotRepository do
  @moduledoc "In-memory SnapshotRepository for engine tests."
  @behaviour ArmchairMetropolist.Domain.Ports.SnapshotRepository

  use Agent

  def start_link(_ \\ []) do
    Agent.start_link(fn -> %{initial: {:error, :not_found}, saves: []} end, name: __MODULE__)
  end

  @doc "Seed what load_latest/0 will return."
  def set_initial(result), do: Agent.update(__MODULE__, &%{&1 | initial: result})

  @doc "Every {tick, city_map} passed to save/2, newest first."
  def saves, do: Agent.get(__MODULE__, & &1.saves)

  @impl true
  def load_latest, do: Agent.get(__MODULE__, & &1.initial)

  @impl true
  def save(tick, city_map) do
    Agent.update(__MODULE__, &%{&1 | saves: [{tick, city_map} | &1.saves]})
    :ok
  end
end
