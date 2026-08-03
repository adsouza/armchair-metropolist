defmodule ArmchairMetropolist.StubSnapshotRepository do
  @moduledoc "In-memory SnapshotRepository for engine tests."

  # Test-support module: own top-level boundary with checks disabled, see
  # ArmchairMetropolist.StubNotifier for the rationale.
  use Boundary, top_level?: true, check: [in: false, out: false]

  @behaviour ArmchairMetropolist.Domain.Ports.SnapshotRepository

  use Agent

  def start_link(_ \\ []) do
    Agent.start_link(fn -> %{initial: {:error, :not_found}, saves: []} end, name: __MODULE__)
  end

  @doc "Seed what load/1 will return."
  def set_initial(result), do: Agent.update(__MODULE__, &%{&1 | initial: result})

  @doc "Every {city_id, tick, city_map} passed to save/3, newest first."
  def saves, do: Agent.get(__MODULE__, & &1.saves)

  @impl true
  def load(_city_id), do: Agent.get(__MODULE__, & &1.initial)

  @impl true
  def save(city_id, tick, city_map) do
    Agent.update(__MODULE__, &%{&1 | saves: [{city_id, tick, city_map} | &1.saves]})
    :ok
  end
end
