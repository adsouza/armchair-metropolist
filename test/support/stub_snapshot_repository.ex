defmodule ArmchairMetropolist.StubSnapshotRepository do
  @moduledoc "In-memory SnapshotRepository for engine tests."

  # Test-support module: own top-level boundary with checks disabled, see
  # ArmchairMetropolist.StubNotifier for the rationale.
  use Boundary, top_level?: true, check: [in: false, out: false]

  @behaviour ArmchairMetropolist.Domain.Ports.SnapshotRepository

  use Agent

  def start_link(_ \\ []) do
    Agent.start_link(
      fn -> %{initial: {:error, :not_found}, saves: [], calls: []} end,
      name: __MODULE__
    )
  end

  @doc "Seed what load/1 will return."
  def set_initial(result), do: Agent.update(__MODULE__, &%{&1 | initial: result})

  @doc "Every {city_id, order, city_map} passed to save/3, newest first."
  def saves, do: Agent.get(__MODULE__, & &1.saves)

  @doc """
  Make the next `save/3` refuse with `{:stale, tick}`.

  Only the engine's handling of a refusal needs this; the real adapters' own refusal
  logic is covered by the shared contract.
  """
  def refuse_saves_as_stale(stored_order) do
    Agent.update(__MODULE__, &Map.put(&1, :stale_at, stored_order))
  end

  @doc "Make load/1 return the most recent save/3, as a real adapter would."
  def echo_saves, do: Agent.update(__MODULE__, &Map.put(&1, :echo, true))

  @impl true
  def load(city_id) do
    Agent.get(__MODULE__, fn state ->
      case state do
        %{echo: true, saves: [{^city_id, order, city_map} | _]} -> {:ok, {order, city_map}}
        _ -> state.initial
      end
    end)
  end

  @impl true
  def save(city_id, order, city_map) do
    # get_and_update/2 rather than a separate get then update: the flag has to be
    # both read and cleared in one step, or a second save between the two calls
    # could see a `:stale_at` that a concurrent caller had already consumed.
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state, :stale_at) do
        nil ->
          {:ok,
           %{
             state
             | saves: [{city_id, order, city_map} | state.saves],
               calls: [{:save, city_id, order} | state.calls]
           }}

        stored_tick ->
          {{:stale, stored_tick}, Map.delete(state, :stale_at)}
      end
    end)
  end

  @doc """
  Every accepted `save/3` and every `delete/1`, newest first — not literally every
  call. A `save/3` refused via `refuse_saves_as_stale/1` does not append here, and
  `load/1` is never recorded at all.

  `saves/0` answers "what was written"; this answers "in what order, against what
  else". The engine's reset has to delete before it saves, so the ordering between
  an accepted save and a delete is behaviour worth asserting rather than an
  implementation detail.
  """
  def calls, do: Agent.get(__MODULE__, & &1.calls)

  @doc "Make delete/1 fail, to prove the engine still resets in memory."
  def fail_deletes(reason) do
    Agent.update(__MODULE__, &Map.put(&1, :delete_result, {:error, reason}))
  end

  @impl true
  def delete(city_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      calls = [{:delete, city_id} | state.calls]

      case Map.get(state, :delete_result, :ok) do
        # Clears `saves` as well as answering, so a subsequent `saves/0` reports what
        # the engine wrote *after* the wipe rather than the discarded city's history.
        # Note this does not make `load/1` report nothing: under `echo_saves/0` an empty
        # `saves` falls back to whatever `set_initial/1` seeded, which is the old city.
        # No test relies on that path today; a future one that does needs a real
        # tombstone here rather than an empty list.
        :ok -> {:ok, %{state | saves: [], calls: calls}}
        error -> {error, %{state | calls: calls}}
      end
    end)
  end
end
