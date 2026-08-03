defmodule ArmchairMetropolist.Infrastructure.Simulation.CityEngine do
  @moduledoc """
  Owns the in-memory CityMap state and coordinates simulation ticks.

  ## Lifecycle

  `init/1` traps exits and returns `{:continue, :hydrate}`. Both are load-bearing:

    * **Trapping exits** is what makes `terminate/2` run at all. A GenServer that
      does not trap exits is killed outright by the supervisor's shutdown signal,
      so the save-on-shutdown guarantee below would be silently false.
    * **Hydrating in `handle_continue/2`** keeps the snapshot read out of `init/1`,
      so a slow database delays only this process instead of blocking the whole
      supervision tree at boot. `handle_continue` runs before any mailbox message,
      so no tick can ever be handled before the city map exists.

  State is persisted in two places: on every `checkpoint_every_ticks`-th tick, and
  synchronously in `terminate/2` — which needs the `shutdown: 10_000` in this
  module's child spec, since the 5s default can kill the process mid-write.

  ## Two tick counters, one authority

  `TickServer` broadcasts `{:tick, n}` where `n` counts clock pulses since the
  clock started. The engine **ignores** `n`: it is diagnostic only, and a
  restarted clock resets it. The authoritative simulation tick is `city_map.tick`,
  advanced by `AdvanceCityTick` and written to storage. Everything user-visible
  uses `city_map.tick`.

  ## Broadcasts

  On `"city_simulation"`: `{:city_delta, delta}` on every tick; `{:city_metrics,
  metrics}` on every tick and on every successful `place`/`demolish`;
  `{:city_node_placed, node}` and `{:city_node_removed, id}` on successful commands.
  Rejected commands broadcast nothing.

  ## Critical deficit notifications

  A resource is in *critical deficit* when its satisfaction is below `1.0` —
  that is, when any of its demand goes unmet. The threshold needs no
  epsilon: `SimulationCalculator` computes satisfaction as
  `min(1.0, supply / demand)` and returns exactly `1.0` for a resource with no
  demand, so a fully supplied city compares equal to `1.0` rather than merely
  close to it.

  The engine notifies on the tick a deficit *begins* and then holds a `critical?`
  flag until every resource is satisfied again, which re-arms it. Notifying on
  every tick of a sustained blackout would make notifications unusable.

  ## `metrics.resources` at hydration

  `snapshot/0` reports full resource statistics from the moment the engine hydrates,
  before any tick has run. `Infrastructure` cannot reach `SimulationCalculator`
  directly — the boundary graph forbids it — so the figures come via
  `UseCases.SummarizeCity`. This used to be an empty map, and a LiveView mounting in
  that window had nothing to render; `city_engine_test.exs` has a regression test for
  it.
  """

  use GenServer, shutdown: 10_000

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Entities.SimulationMetrics
  alias ArmchairMetropolist.UseCases.AdvanceCityTick
  alias ArmchairMetropolist.UseCases.ManageInfrastructure
  alias ArmchairMetropolist.UseCases.SummarizeCity

  require Logger

  @tick_topic "city_tick"
  @simulation_topic "city_simulation"

  @default_grid_width 40
  @default_grid_height 30
  @default_checkpoint_every_ticks 50
  @default_city_id "default"

  # Satisfaction below this counts as a critical deficit. See the moduledoc.
  @critical_satisfaction 1.0

  @doc "The topic every simulation event is broadcast on."
  def topic, do: @simulation_topic

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The current city map and the metrics of the most recent tick.
  """
  @spec snapshot() :: {:ok, %{city_map: CityMap.t(), metrics: SimulationMetrics.t()}}
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc """
  Place a node of `type` at `(x, y)`.
  """
  @spec place(integer(), integer(), atom()) ::
          {:ok, ArmchairMetropolist.Domain.Entities.Node.t()}
          | {:error, :out_of_bounds | :occupied | :unknown_type}
  def place(x, y, type), do: GenServer.call(__MODULE__, {:place, x, y, type})

  @doc """
  Remove the node at `(x, y)`.
  """
  @spec demolish(integer(), integer()) :: {:ok, String.t()} | {:error, :empty}
  def demolish(x, y), do: GenServer.call(__MODULE__, {:demolish, x, y})

  @impl true
  def init(opts) do
    # Mandatory. Without this the supervisor's shutdown signal kills the process
    # immediately, terminate/2 never runs, and unsaved state is lost.
    Process.flag(:trap_exit, true)

    :ok = Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, @tick_topic)

    # Task 2 makes this process addressable by this id. For now it is a singleton that
    # simply knows which row it owns, which is what lets the port change land on its
    # own and be tested on its own.
    city_id = Keyword.get(opts, :city_id, @default_city_id)

    {:ok, %{city_id: city_id, city_map: nil, metrics: nil, critical?: false},
     {:continue, :hydrate}}
  end

  @impl true
  def handle_continue(:hydrate, state) do
    city_map = load_city_map(state.city_id)

    {:noreply, %{state | city_map: city_map, metrics: summarize(city_map)}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, {:ok, %{city_map: state.city_map, metrics: state.metrics}}, state}
  end

  def handle_call({:place, x, y, type}, _from, state) do
    case ManageInfrastructure.place(state.city_map, x, y, type) do
      {:ok, {city_map, node}} ->
        metrics = summarize(city_map)
        broadcast({:city_node_placed, node})
        # Commands change the city, so subscribers need the new figures now. Without
        # this the legend's counts would not move until the next tick — and in tests,
        # where no clock runs, never.
        broadcast({:city_metrics, metrics})
        {:reply, {:ok, node}, %{state | city_map: city_map, metrics: metrics}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:demolish, x, y}, _from, state) do
    case ManageInfrastructure.demolish(state.city_map, x, y) do
      {:ok, {city_map, node_id}} ->
        metrics = summarize(city_map)
        broadcast({:city_node_removed, node_id})
        broadcast({:city_metrics, metrics})
        {:reply, {:ok, node_id}, %{state | city_map: city_map, metrics: metrics}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # The clock's pulse number is deliberately discarded: city_map.tick is the
  # authority.
  @impl true
  def handle_info({:tick, _clock_pulse}, state) do
    {:ok, %{city_map: city_map, delta: delta, metrics: metrics}} =
      AdvanceCityTick.execute(state.city_map)

    broadcast({:city_delta, delta})
    broadcast({:city_metrics, metrics})
    maybe_checkpoint(state.city_id, city_map)
    critical? = notify_deficits(metrics, state.critical?)

    {:noreply, %{state | city_map: city_map, metrics: metrics, critical?: critical?}}
  end

  # Anyone may broadcast on the subscribed topic, so unrecognised messages are
  # dropped rather than allowed to crash the engine and lose the city.
  def handle_info(message, state) do
    Logger.debug("CityEngine ignoring unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{city_map: nil}), do: :ok

  # `save/2` swallows and logs every failure, so a broken repository cannot stall
  # or abort shutdown here — the process still exits within its 10s budget.
  def terminate(_reason, state) do
    save(state.city_id, state.city_map)
  end

  defp load_city_map(city_id) do
    case snapshot_repository().load(city_id) do
      {:ok, {_stored_tick, city_map}} ->
        # The stored tick is only the repository's ordering key, and it is
        # written from city_map.tick; the map itself carries the authority.
        normalize_city_map(city_map)

      {:error, :not_found} ->
        new_city_map()

      {:error, reason} ->
        Logger.warning("could not load city snapshot (#{inspect(reason)}), starting a new city")
        new_city_map()
    end
  end

  @doc false
  # A stored city is whatever shape CityMap had when it was written. Decoding gives
  # back a struct with only those keys, so a field added later is *missing*, not
  # defaulted, and the first read raises KeyError long after the load succeeded.
  # Merging onto a fresh struct fills new fields and leaves stored ones alone.
  def normalize_city_map(stored) when is_map(stored) do
    Map.merge(%CityMap{}, Map.delete(stored, :__struct__))
  end

  defp new_city_map do
    CityMap.new(
      config(:grid_width, @default_grid_width),
      config(:grid_height, @default_grid_height)
    )
  end

  defp maybe_checkpoint(city_id, city_map) do
    every = config(:checkpoint_every_ticks, @default_checkpoint_every_ticks)

    if checkpoint?(city_map.tick, every) do
      save(city_id, city_map)
    else
      :ok
    end
  end

  # A non-positive or non-integer interval disables checkpointing. Without this
  # clause `rem(tick, 0)` raises inside handle_info/2, so a single bad config
  # value would put the engine in a restart loop that never persists anything —
  # a far worse failure than not checkpointing.
  #
  # The `tick > 0` test matches the spec literally. It is also unreachable by
  # construction: maybe_checkpoint/2 only ever sees the map *after*
  # AdvanceCityTick has run, so the tick is always >= 1. It stays as a guard
  # against a future caller that checkpoints a freshly hydrated city.
  defp checkpoint?(tick, every) when is_integer(every) and every > 0 do
    tick > 0 and rem(tick, every) == 0
  end

  defp checkpoint?(_tick, _every), do: false

  # Never raises, and never returns anything but :ok. A failed snapshot must not
  # take the engine down with it: the supervisor would restart it, hydration would
  # roll the city back to the *previous* checkpoint, and every tick since would be
  # gone. Losing one snapshot costs the player nothing they can see; losing a
  # checkpoint interval of state costs them everything they did in it. And because
  # the checkpoints are `checkpoint_every_ticks` apart, such a restart loop never
  # trips `max_restarts` — it just quietly discards work forever.
  defp save(city_id, city_map) do
    case snapshot_repository().save(city_id, city_map.tick, city_map) do
      :ok -> :ok
      {:error, reason} -> log_failed_save(city_map.tick, reason)
    end
  rescue
    # Both shipped adapters honour the port's `{:error, term()}`. These two clauses
    # are for the one that does not — a swapped-in adapter, or a bang call that
    # creeps back in — and for `terminate/2`, where a raise would also abandon the
    # final write.
    exception -> log_failed_save(city_map.tick, exception)
  catch
    kind, value -> log_failed_save(city_map.tick, {kind, value})
  end

  defp log_failed_save(tick, reason) do
    Logger.error("failed to persist city snapshot at tick #{tick}: #{inspect(reason)}")

    :ok
  end

  # Returns the next value of the critical? flag: notify on the tick the deficit
  # begins, stay quiet while it persists, re-arm when everything is satisfied.
  defp notify_deficits(metrics, critical?) do
    case {critical_resources(metrics), critical?} do
      {[], _} ->
        false

      {_resources, true} ->
        true

      {resources, false} ->
        notify(resources)
        true
    end
  end

  defp critical_resources(metrics) do
    metrics.resources
    |> Enum.filter(fn {_resource, stats} -> stats.satisfaction < @critical_satisfaction end)
    |> Enum.sort_by(fn {_resource, stats} -> stats.satisfaction end)
  end

  defp notify(resources) do
    body =
      Enum.map_join(resources, ", ", fn {resource, stats} ->
        "#{resource} at #{round(stats.satisfaction * 100)}% of demand"
      end)

    case notifier().notify("City resources in deficit", body) do
      :ok -> :ok
      {:error, reason} -> Logger.error("notification failed: #{inspect(reason)}")
    end
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(ArmchairMetropolist.PubSub, @simulation_topic, message)
  end

  # Both adapters are resolved per call so tests can inject stubs and the
  # desktop target can swap the repository without recompiling this module.
  defp snapshot_repository do
    config(:snapshot_repository, ArmchairMetropolist.Infrastructure.Persistence.SnapshotStore)
  end

  # Metrics have to come through UseCases: the boundary graph bars Infrastructure
  # from Domain.Services, so this process cannot call SimulationCalculator itself.
  defp summarize(city_map) do
    {:ok, metrics} = SummarizeCity.execute(city_map)
    metrics
  end

  defp notifier do
    config(:notifier, ArmchairMetropolist.Infrastructure.Desktop.LogNotifier)
  end

  defp config(key, default), do: Application.get_env(:armchair_metropolist, key, default)
end
