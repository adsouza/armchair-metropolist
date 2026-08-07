defmodule ArmchairMetropolist.SlowSnapshotRepository do
  @moduledoc """
  A SnapshotRepository whose `load/1` stalls, standing in for a slow
  database.

  Exists to prove hydration happens in `handle_continue/2` rather than `init/1`:
  `CityEngine.start_link/1` must return long before this adapter answers.
  Everything else is delegated to `StubSnapshotRepository`, so the usual
  `set_initial/1` and `saves/0` helpers still work.
  """

  # Test-support module: own top-level boundary with checks disabled, see
  # ArmchairMetropolist.StubNotifier for the rationale.
  use Boundary, top_level?: true, check: [in: false, out: false]

  @behaviour ArmchairMetropolist.Domain.Ports.SnapshotRepository

  alias ArmchairMetropolist.StubSnapshotRepository

  @delay_ms 400

  @doc "How long load/1 stalls for."
  def delay_ms, do: @delay_ms

  @impl true
  def load(city_id) do
    Process.sleep(@delay_ms)
    StubSnapshotRepository.load(city_id)
  end

  @impl true
  def save(city_id, tick, city_map), do: StubSnapshotRepository.save(city_id, tick, city_map)

  @impl true
  def delete(city_id), do: StubSnapshotRepository.delete(city_id)
end
