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

  ## Freezing a collapsed city

  When `metrics.stalled` is true the engine ignores `{:tick, n}` entirely: no
  `AdvanceCityTick`, no broadcast, no checkpoint, no deficit notification. See the
  clause itself for why this preserves the treasury rather than merely saving work.

  ## Broadcasts

  On `topic(city_id)`: `{:city_delta, delta}` on every tick; `{:city_metrics,
  metrics}` on every tick and on every successful `place`/`demolish`;
  `{:city_node_placed, node}` and `{:city_node_removed, id}` on successful commands.
  `:city_reset` on a successful `reset/1`, followed by `{:city_metrics, metrics}`.
  Rejected commands broadcast nothing. Each city's events land on their own topic —
  a shared one would deliver every visitor's deltas to every other visitor.

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

  A deficit begins when a *satisfied* city stops being one, and that comparison has
  to survive the process. `handle_continue(:hydrate, ...)` therefore seeds `critical?`
  from the hydrated city's own metrics instead of `init/1`'s `false`: a city restored
  mid-deficit is not a city that just entered one. Without that, every relaunch,
  crash-restart and post-linger restart re-announced a deficit the player had already
  been told about — the desktop log showed three byte-identical notifications, one per
  launch of an app whose city had not changed in between.

  The consequence worth knowing: a deficit that no tick ever evaluated is never
  announced. `place/4` recomputes metrics but deliberately does not notify, so
  building consumers and quitting inside the same tick stores an unannounced deficit
  that hydration then treats as old news. That window is one tick wide, and the
  alternative — persisting an "already notified" flag beside the city — stores a copy
  of a fact the city already determines, free to drift from it.

  ## `metrics.resources` at hydration

  `snapshot/1` reports full resource statistics from the moment the engine hydrates,
  before any tick has run. `Infrastructure` cannot reach `SimulationCalculator`
  directly — the boundary graph forbids it — so the figures come via
  `UseCases.SummarizeCity`. This used to be an empty map, and a LiveView mounting in
  that window had nothing to render; `city_engine_test.exs` has a regression test for
  it.
  """

  # `restart: :transient`, not the default `:permanent`: `handle_info(:linger_expired,
  # ...)` stops this process on purpose with reason `:normal` once every viewer has
  # gone, and a `:permanent` child is restarted by CityRegistry's DynamicSupervisor
  # no matter how it exits - including `:normal` - which would resurrect the engine
  # the instant it froze and defeat the whole task. `:transient` still restarts on an
  # abnormal exit, so a genuine crash keeps today's recovery behaviour.
  use GenServer, shutdown: 10_000, restart: :transient

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Entities.SimulationMetrics
  alias ArmchairMetropolist.Infrastructure.Simulation.CityRegistry
  alias ArmchairMetropolist.UseCases.AdvanceCityTick
  alias ArmchairMetropolist.UseCases.ManageInfrastructure
  alias ArmchairMetropolist.UseCases.ResetCity
  alias ArmchairMetropolist.UseCases.SummarizeCity

  require Logger

  @tick_topic "city_tick"

  @default_grid_width 40
  @default_grid_height 30
  @default_checkpoint_every_ticks 50
  @default_city_id "default"
  @default_linger_ms 30_000
  # Short on purpose - see handle_continue(:hydrate, ...) for why this timer needs
  # to be much shorter than the post-viewer linger above.
  @default_unattached_linger_ms 2_000

  # Satisfaction below this counts as a critical deficit. See the moduledoc.
  @critical_satisfaction 1.0

  @doc "The topic this city's simulation events are broadcast on."
  def topic(city_id) when is_binary(city_id), do: "city:" <> city_id

  @doc """
  A stable, arbitrary city id.

  Has no production reader: the desktop target addresses its city via
  `Desktop.Config`'s own `:desktop_city_id` (a separate constant, `"desktop"`), and
  the web target mints or reads one per session. This exists only so tests that need
  a fixed id to pin a session or a `start_supervised!/1` engine to — so the view
  under test and the test's own assertions agree on which city they mean — have one
  written down in exactly one place rather than repeating a literal string.
  """
  def default_city_id, do: @default_city_id

  def start_link(opts) do
    city_id = Keyword.fetch!(opts, :city_id)

    GenServer.start_link(__MODULE__, opts, name: CityRegistry.via(city_id))
  end

  @doc """
  The current city map and the metrics of the most recent tick.
  """
  @spec snapshot(String.t()) :: {:ok, %{city_map: CityMap.t(), metrics: SimulationMetrics.t()}}
  def snapshot(city_id), do: call(city_id, :snapshot)

  @doc """
  Place a node of `type` at `(x, y)`.
  """
  @spec place(String.t(), integer(), integer(), atom()) ::
          {:ok, ArmchairMetropolist.Domain.Entities.Node.t()}
          | {:error, :out_of_bounds | :occupied | :unknown_type | :insufficient_funds}
  def place(city_id, x, y, type), do: call(city_id, {:place, x, y, type})

  @doc """
  Remove the node at `(x, y)`.
  """
  @spec demolish(String.t(), integer(), integer()) ::
          {:ok, String.t()} | {:error, :empty | :insufficient_funds}
  def demolish(city_id, x, y), do: call(city_id, {:demolish, x, y})

  @doc """
  Discard this city and start a new one on the same grid.

  Deletes the stored snapshot, so the tick-0 city that replaces it is durable
  immediately rather than unsaveable until it outlives the city it replaced.
  """
  @spec reset(String.t()) :: :ok
  def reset(city_id), do: call(city_id, :reset)

  @doc """
  Register `pid` as a viewer of `city_id`.

  The engine monitors it, and stops once every viewer has gone — see the moduledoc
  on freezing. Idempotent per pid: attaching twice monitors twice and both
  references are removed independently, which is harmless.
  """
  def attach(city_id, pid) when is_binary(city_id) and is_pid(pid) do
    call(city_id, {:attach, pid})
  end

  # Start-on-demand, then call. The retry exists because an engine can stop between
  # `ensure_started/1` and the call — idle engines stop themselves on purpose (see
  # the freezing section of the moduledoc), so this is a normal race rather than an
  # exotic one. One retry is enough: the second `ensure_started/1` cannot find a
  # stopping process, because a stopped process is unregistered before the next
  # lookup.
  defp call(city_id, message, retries \\ 1) do
    {:ok, _pid} = CityRegistry.ensure_started(city_id)

    try do
      GenServer.call(CityRegistry.via(city_id), message)
    catch
      :exit, {reason, _} when retries > 0 and reason in [:noproc, :normal, :shutdown] ->
        call(city_id, message, retries - 1)
    end
  end

  @impl true
  def init(opts) do
    # Mandatory. Without this the supervisor's shutdown signal kills the process
    # immediately, terminate/2 never runs, and unsaved state is lost.
    Process.flag(:trap_exit, true)

    :ok = Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, @tick_topic)

    # start_link/1 already requires :city_id and names this process by it via
    # CityRegistry.via/1, so Keyword.fetch! there guarantees it is present here too.
    # get/3 with the default is kept anyway for direct callers that construct this
    # GenServer's init argument without going through start_link/1 - init/1 has no
    # other way to know what id to hydrate under.
    city_id = Keyword.get(opts, :city_id, @default_city_id)

    {:ok,
     %{
       city_id: city_id,
       city_map: nil,
       metrics: nil,
       critical?: false,
       viewers: %{},
       linger: nil
     }, {:continue, :hydrate}}
  end

  @impl true
  def handle_continue(:hydrate, state) do
    city_map = load_city_map(state.city_id)

    # Freezing is otherwise triggered only by a viewer *leaving* (see
    # handle_info({:DOWN, ...}) below), so an engine that never had one has nothing
    # to stop it. That is reachable: SimulatorLive's dead render starts an engine
    # via CityEngine.snapshot/1 before connected?(socket) is true, so before
    # attach/2 is ever called on it. On the ordinary path the live mount that
    # follows shares the dead render's city id and attaches to this same process,
    # cancelling this timer - but a client that never completes that live mount
    # (or one routed to a different city id for it) would otherwise run forever.
    # Arming here makes whether this engine ever stops a property of the engine,
    # not of routing ensuring every dead render is eventually attached to.
    # handle_info(:linger_expired, ...) already re-checks the viewer set, so a
    # viewer that attaches in time is all this needs to be cancelled safely.
    #
    # Uses :engine_unattached_linger_ms, a separate and much shorter timer than the
    # post-:DOWN :engine_linger_ms below - deliberately. EnsureCityId hands every
    # session-less request its own city id, so every cookieless HTTP GET (a
    # crawler, a scanner, a health check with no cookie jar) starts a distinct
    # engine this way; with the 30s post-viewer linger that engine stayed
    # subscribed to the global clock and ticking for 30s per request, which at a
    # modest request rate sustains hundreds of live engines. A real visitor's live
    # mount follows the dead render within about a second and cancels this timer
    # long before it matters, so this window only needs to be wide enough to
    # absorb that ordinary case - not the 30s that exists to absorb a page *reload*
    # after a viewer has actually been present, which this path is not.
    metrics = summarize(city_map)

    {:noreply,
     %{
       state
       | city_map: city_map,
         metrics: metrics,
         # A hydrated city brings its deficits with it, so arriving in one is not the
         # edge this notification reports - whichever process was running when the
         # deficit began has already reported it. Left at init/1's `false`, every
         # relaunch, crash-restart and post-linger restart was a fresh edge, and the
         # desktop log showed exactly that: three byte-identical notifications, one
         # per launch of an app whose city had not changed in between.
         #
         # Derived here rather than persisted alongside the city on purpose. The
         # deficit is already stored - it is a property of the stored nodes - so a
         # stored flag would be a second copy of a fact that can be recomputed, free
         # to drift from it. And this recomputation is exact, not an approximation:
         # AdvanceCityTick builds its metrics from the *post*-tick map, so these are
         # the very figures the last tick before the save evaluated, which makes this
         # the flag that process was holding when it went away.
         critical?: critical_resources(metrics) != [],
         linger: arm_linger(:engine_unattached_linger_ms, @default_unattached_linger_ms)
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, {:ok, %{city_map: state.city_map, metrics: state.metrics}}, state}
  end

  def handle_call({:place, x, y, type}, _from, state) do
    case ManageInfrastructure.place(state.city_map, x, y, type) do
      {:ok, {city_map, node}} ->
        metrics = summarize(city_map)
        broadcast(state.city_id, {:city_node_placed, node})
        # Commands change the city, so subscribers need the new figures now. Without
        # this the legend's counts would not move until the next tick — and in tests,
        # where no clock runs, never.
        broadcast(state.city_id, {:city_metrics, metrics})
        {:reply, {:ok, node}, %{state | city_map: city_map, metrics: metrics}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:demolish, x, y}, _from, state) do
    case ManageInfrastructure.demolish(state.city_map, x, y) do
      {:ok, {city_map, node_id}} ->
        metrics = summarize(city_map)
        broadcast(state.city_id, {:city_node_removed, node_id})
        broadcast(state.city_id, {:city_metrics, metrics})
        {:reply, {:ok, node_id}, %{state | city_map: city_map, metrics: metrics}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:reset, _from, state) do
    {:ok, %{city_map: city_map, metrics: metrics}} = ResetCity.execute(state.city_map)

    # Delete first, then save — and the order is the error handling. `save/3` is
    # monotonic in tick, so with the old row still present this save at tick 0 is
    # refused as `{:stale, _}` and lands in `save/2`'s existing warning path, which
    # already means "this engine's city is older than what is stored". A failed delete
    # therefore reports itself through a path that exists, with no new branch and no new
    # error policy. Reversed, the save would be refused *before* the delete and the new
    # city would never reach storage at all.
    #
    # Saving here rather than waiting for the next checkpoint: a player who wipes and
    # immediately closes the tab would otherwise get the collapsed city back.
    delete(state.city_id)
    save(state.city_id, city_map)

    broadcast(state.city_id, :city_reset)
    broadcast(state.city_id, {:city_metrics, metrics})

    # Re-armed from the new city rather than left as it was, so the next deficit is a
    # fresh edge. An empty city has no deficit, so this is `false` in practice; deriving
    # it keeps that a consequence of the city rather than a second thing to remember.
    {:reply, :ok,
     %{
       state
       | city_map: city_map,
         metrics: metrics,
         critical?: critical_resources(metrics) != []
     }}
  end

  def handle_call({:attach, pid}, _from, state) do
    ref = Process.monitor(pid)

    {:reply, :ok,
     %{state | viewers: Map.put(state.viewers, ref, pid), linger: cancel_linger(state.linger)}}
  end

  # A stalled city has reached a fixpoint in health, so advancing it would recompute an
  # identical result — but this is not only an optimisation. Money demand is not
  # health-scaled either, so a stalled city with a water plant, transit hub or park goes
  # on draining its treasury, and that treasury is exactly what a rescue is paid for.
  # Freezing preserves it, which makes "stalled but solvent" a stable state a player can
  # act on rather than a countdown.
  #
  # Not a lockout: `handle_call({:place, …})` does not tick, so a player with money left
  # can still build, the recomputed metrics clear this flag, and the clock resumes on the
  # next pulse.
  #
  # Nothing is persisted for this. `handle_continue(:hydrate, …)` recomputes metrics, so a
  # stalled city loads stalled and stays frozen — the same reasoning that keeps `critical?`
  # derived rather than stored.
  @impl true
  def handle_info({:tick, _clock_pulse}, %{metrics: %{stalled: true}} = state) do
    {:noreply, state}
  end

  # The clock's pulse number is deliberately discarded: city_map.tick is the
  # authority.
  def handle_info({:tick, _clock_pulse}, state) do
    {:ok, %{city_map: city_map, delta: delta, metrics: metrics}} =
      AdvanceCityTick.execute(state.city_map)

    broadcast(state.city_id, {:city_delta, delta})
    broadcast(state.city_id, {:city_metrics, metrics})
    maybe_checkpoint(state.city_id, city_map)
    critical? = notify_deficits(metrics, state.critical?)

    {:noreply, %{state | city_map: city_map, metrics: metrics, critical?: critical?}}
  end

  # A viewer's LiveView process has gone. When the last one goes, save immediately —
  # the city is frozen from this instant and the save must not wait for the linger,
  # which might be cut short by an application shutdown.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    viewers = Map.delete(state.viewers, ref)

    if map_size(viewers) == 0 do
      save(state.city_id, state.city_map)

      {:noreply,
       %{state | viewers: viewers, linger: arm_linger(:engine_linger_ms, @default_linger_ms)}}
    else
      {:noreply, %{state | viewers: viewers}}
    end
  end

  def handle_info(:linger_expired, state) do
    # A viewer that arrived during the linger cancelled the timer, so reaching here
    # with viewers present means a cancel raced a fired message. Checking rather than
    # trusting the timer is what stops that race from killing a watched city.
    if map_size(state.viewers) == 0 do
      {:stop, :normal, state}
    else
      {:noreply, %{state | linger: nil}}
    end
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
  #
  # When the stop came from handle_info(:linger_expired, ...), this is a second save
  # following the :DOWN handler's. Whether it saves an unchanged city_map now depends on
  # whether the city is stalled — the per-visitor design's "a frozen city does not
  # advance" was written about the no-viewer case covered in the next paragraph, before
  # this branch gave "frozen" its own meaning for a stalled city's tick.
  #
  # An unstalled city keeps ticking while abandoned: the engine stays subscribed to
  # "city_tick" throughout the linger, so a full linger window's worth of ticks (~30 at
  # the default engine_linger_ms) can land between the two saves, and this one is a real
  # write of a map that has moved on since. (That is the per-visitor design's deviation:
  # an abandoned city advances for up to the linger window after its last viewer leaves,
  # not indefinitely.)
  #
  # A stalled city is the opposite: its tick is frozen, so no tick lands during the
  # linger, the map here is identical to what the :DOWN handler already saved, and this
  # second save is refused `{:stale, _}` and logs a warning rather than being
  # idempotent — see save/2's comment for why that warning is harmless.
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
      :ok ->
        :ok

      # Not a failure — the adapter refused to move the city backwards. Worth a warning
      # rather than silence, because reaching here has three causes. One is a
      # crash-and-replay, where this engine hydrated from an older snapshot than the
      # one stored — the exact case the guarantee exists for. Another is an ordinary
      # shutdown of a stalled city: its tick never advances, so the :DOWN handler's
      # save and terminate/2's save both carry the same tick, and the second is always
      # refused. The third is `handle_call(:reset, …)` when its preceding `delete/1`
      # failed: the old row is still there at its old tick, so the reset's save at
      # tick 0 lands here too — see that handler's comment. None of the three threatens
      # durability: the city is already durable, either at the tick already stored or
      # at the tick this call just tried to write. Only the stalled-shutdown case is
      # noise, though: for crash-and-replay this warning is the only evidence a replay
      # happened, and for a failed-delete reset it corroborates the error delete/1
      # already logged.
      {:stale, stored_tick} ->
        Logger.warning(
          "declined to persist city #{city_id} at tick #{city_map.tick}: " <>
            "a newer snapshot at tick #{stored_tick} is already stored"
        )

      {:error, reason} ->
        log_failed_save(city_map.tick, reason)
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

  # Never raises, and never returns anything but `:ok` — same policy as `save/2`, and for
  # the same reason: this runs inside a `handle_call`, and a raise here would take the
  # city down and roll it back to the last checkpoint. The consequence of a swallowed
  # failure is bounded and visible: the save that follows is refused as stale and logs.
  defp delete(city_id) do
    case snapshot_repository().delete(city_id) do
      :ok -> :ok
      {:error, reason} -> log_failed_delete(city_id, reason)
    end
  rescue
    exception -> log_failed_delete(city_id, exception)
  catch
    kind, value -> log_failed_delete(city_id, {kind, value})
  end

  defp log_failed_delete(city_id, reason) do
    Logger.error("failed to delete city snapshot for #{city_id}: #{inspect(reason)}")

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
        # Clamped at the display layer only — see SimulatorLive.tightest_resource/1
        # for the identical reasoning. critical_resources/1's own filter and sort,
        # just above, stay on the signed value so waste still ranks first.
        "#{resource} at #{max(0, round(stats.satisfaction * 100))}% of demand"
      end)

    case notifier().notify("City resources in deficit", body) do
      :ok -> :ok
      {:error, reason} -> Logger.error("notification failed: #{inspect(reason)}")
    end
  end

  defp broadcast(city_id, message) do
    Phoenix.PubSub.broadcast(ArmchairMetropolist.PubSub, topic(city_id), message)
  end

  # Two distinct config keys share this one timer mechanism, deliberately: the
  # pre-attach linger (handle_continue(:hydrate, ...)) absorbs the gap before a dead
  # render's live mount attaches, and the post-:DOWN linger (handle_info({:DOWN,
  # ...}), above) absorbs a page reload after a viewer has actually been present.
  # Those are different windows with different costs to getting wrong, hence
  # separate keys rather than one - see handle_continue(:hydrate, ...)'s comment.
  defp arm_linger(config_key, default_ms) do
    Process.send_after(self(), :linger_expired, config(config_key, default_ms))
  end

  defp cancel_linger(nil), do: nil

  defp cancel_linger(timer) do
    Process.cancel_timer(timer)
    nil
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
