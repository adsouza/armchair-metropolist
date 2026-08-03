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

  @doc """
  Make the next `save/3` refuse with `{:stale, tick}`.

  Only the engine's handling of a refusal needs this; the real adapters' own refusal
  logic is covered by the shared contract.
  """
  def refuse_saves_as_stale(stored_tick) do
    Agent.update(__MODULE__, &Map.put(&1, :stale_at, stored_tick))
  end

  @impl true
  def load(_city_id), do: Agent.get(__MODULE__, & &1.initial)

  @impl true
  def save(city_id, tick, city_map) do
    case Agent.get(__MODULE__, &Map.get(&1, :stale_at)) do
      nil ->
        Agent.update(__MODULE__, &%{&1 | saves: [{city_id, tick, city_map} | &1.saves]})
        :ok

      stored_tick ->
        {:stale, stored_tick}
    end
  end
end
