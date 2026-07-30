defmodule ArmchairMetropolist.SnapshotRepositoryOrderingContract do
  @moduledoc """
  The half of the SnapshotRepository contract that pins *ordering* semantics.

  `load_latest/0` means **highest tick wins**, not *last write wins*. That
  distinction is invisible while ticks only ever ascend, which is why the
  ascending-only "returns the most recent snapshot" case in
  `ArmchairMetropolist.SnapshotRepositoryContract` passed against both adapters
  for two *different* reasons: `SnapshotStore` orders by `desc: tick`, while
  `FileSnapshotStore` merely read back whatever it happened to write last. The
  descending case below is what tells them apart, and it did:
  `save(9, …)` then `save(1, …)` returned tick 9 from Postgres and tick 1 from
  the file adapter.

  > #### Merge me {: .info}
  >
  > These assertions belong inside `SnapshotRepositoryContract` with the rest of
  > the shared contract. They are a separate module only because the fix wave
  > that added them was not permitted to edit that file. Any new adapter must
  > `use` both.
  """

  # Test-support module: own top-level boundary with checks disabled, see
  # ArmchairMetropolist.StubNotifier for the rationale.
  use Boundary, top_level?: true, check: [in: false, out: false]

  defmacro __using__(adapter: adapter) do
    quote do
      @ordering_adapter unquote(adapter)

      test "load_latest/0 returns the highest tick, not the last written" do
        alias ArmchairMetropolist.Domain.Entities.CityMap, as: OrderingCityMap

        assert :ok = @ordering_adapter.save(9, OrderingCityMap.new(19, 19))
        assert :ok = @ordering_adapter.save(1, OrderingCityMap.new(11, 11))

        assert {:ok, {9, loaded}} = @ordering_adapter.load_latest()
        assert loaded.width == 19
      end

      test "an older tick never demotes a newer stored snapshot" do
        alias ArmchairMetropolist.Domain.Entities.CityMap, as: OrderingCityMap

        # Two stale saves in a row must not walk a newer snapshot out of storage,
        # however many times they happen. On a last-write-wins file adapter the
        # second one also overwrote the backup, losing the tick-9 city for good.
        assert :ok = @ordering_adapter.save(9, OrderingCityMap.new(19, 19))
        assert :ok = @ordering_adapter.save(0, OrderingCityMap.new(40, 30))
        assert :ok = @ordering_adapter.save(0, OrderingCityMap.new(40, 30))

        assert {:ok, {9, loaded}} = @ordering_adapter.load_latest()
        assert loaded.width == 19
      end
    end
  end
end
