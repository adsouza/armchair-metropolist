defmodule ArmchairMetropolist.Infrastructure.Simulation.TickServer do
  @moduledoc """
  GenServer that drives the simulation clock.

  It is a clock and nothing else: on every interval it increments a counter and
  broadcasts `{:tick, n}` on the `"city_tick"` topic. It never references the
  `CityEngine`, so a crashed or slow engine can neither stall nor kill the
  clock — the broadcast is fire-and-forget.

  `n` counts clock pulses since *this* server started and is diagnostic only.
  The authoritative simulation tick is `CityMap.tick`, which the engine owns and
  persists; consumers must never treat `n` as simulation state.

  `:interval_ms` may be passed to `start_link/1` (tests use a fast clock);
  otherwise the configured `:tick_interval_ms` is used.
  """

  use GenServer

  @topic "city_tick"
  @default_interval_ms 1_000

  @doc "The topic every clock pulse is broadcast on."
  def topic, do: @topic

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval_ms =
      Keyword.get_lazy(opts, :interval_ms, fn ->
        Application.get_env(:armchair_metropolist, :tick_interval_ms, @default_interval_ms)
      end)

    {:ok, schedule(%{interval_ms: interval_ms, tick: 0})}
  end

  @impl true
  def handle_info(:tick, state) do
    tick = state.tick + 1
    Phoenix.PubSub.broadcast(ArmchairMetropolist.PubSub, @topic, {:tick, tick})

    {:noreply, schedule(%{state | tick: tick})}
  end

  defp schedule(state) do
    Process.send_after(self(), :tick, state.interval_ms)
    state
  end
end
