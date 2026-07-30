defmodule ArmchairMetropolist.SlowSnapshotRepository do
  @moduledoc """
  A SnapshotRepository whose `load_latest/0` stalls, standing in for a slow
  database.

  Exists to prove hydration happens in `handle_continue/2` rather than `init/1`:
  `CityEngine.start_link/1` must return long before this adapter answers.
  Everything else is delegated to `StubSnapshotRepository`, so the usual
  `set_initial/1` and `saves/0` helpers still work.
  """

  @behaviour ArmchairMetropolist.Domain.Ports.SnapshotRepository

  alias ArmchairMetropolist.StubSnapshotRepository

  @delay_ms 400

  @doc "How long load_latest/0 stalls for."
  def delay_ms, do: @delay_ms

  @impl true
  def load_latest do
    Process.sleep(@delay_ms)
    StubSnapshotRepository.load_latest()
  end

  @impl true
  def save(tick, city_map), do: StubSnapshotRepository.save(tick, city_map)
end
