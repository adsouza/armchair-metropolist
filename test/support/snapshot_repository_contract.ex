defmodule ArmchairMetropolist.SnapshotRepositoryContract do
  @moduledoc """
  Shared assertions every `SnapshotRepository` adapter must satisfy.

  `use` this from an adapter's test and it gains the whole contract. There is
  deliberately only one module to `use`: the ordering assertions below lived in a
  separate `SnapshotRepositoryOrderingContract` for a while, which meant a new
  adapter could `use` one and silently skip the other.

  ## On the ordering cases

  `load_latest/0` means **highest tick wins**, not *last write wins*. That
  distinction is invisible while ticks only ever ascend, which is why the
  ascending-only "returns the most recent snapshot" case passed against both
  adapters for two *different* reasons: `SnapshotStore` orders by `desc: tick`,
  while `FileSnapshotStore` merely read back whatever it happened to write last.
  The descending case is what told them apart — `save(9, …)` then `save(1, …)`
  returned tick 9 from Postgres and tick 1 from the file adapter.

  Keep every assertion here adapter-agnostic. If one adapter needs a case the
  other cannot satisfy, that is a divergence worth naming, not special-casing.
  """

  # Test-support module: own top-level boundary with checks disabled, see
  # ArmchairMetropolist.StubNotifier for the rationale.
  use Boundary, top_level?: true, check: [in: false, out: false]

  defmacro __using__(adapter: adapter) do
    quote do
      alias ArmchairMetropolist.Domain.Entities.{CityMap, Node}

      @adapter unquote(adapter)
      @city_id "contract-city"

      defp sample_city do
        CityMap.new(40, 30)
        |> CityMap.put_node(Node.new(1, 1, :power_plant))
        |> CityMap.put_node(%Node{Node.new(2, 2, :residential) | health: 42.5, status: :degraded})
      end

      test "returns :not_found when nothing is stored" do
        assert {:error, :not_found} = @adapter.load(@city_id)
      end

      test "round-trips a city map" do
        city = sample_city()
        assert :ok = @adapter.save(@city_id, 7, city)
        assert {:ok, {7, loaded}} = @adapter.load(@city_id)
        assert loaded == city
      end

      test "returns the most recent snapshot" do
        assert :ok = @adapter.save(@city_id, 1, sample_city())
        assert :ok = @adapter.save(@city_id, 9, CityMap.new(10, 10))
        assert {:ok, {9, loaded}} = @adapter.load(@city_id)
        assert loaded.width == 10
      end

      test "save/3 returns bare :ok, not {:ok, id}" do
        assert :ok === @adapter.save(@city_id, 3, sample_city())
      end

      test "load/1 returns the highest tick, not the last written" do
        assert :ok = @adapter.save(@city_id, 9, CityMap.new(19, 19))
        assert :ok = @adapter.save(@city_id, 1, CityMap.new(11, 11))

        assert {:ok, {9, loaded}} = @adapter.load(@city_id)
        assert loaded.width == 19
      end

      test "an older tick never demotes a newer stored snapshot" do
        # Two stale saves in a row must not walk a newer snapshot out of storage,
        # however many times they happen. On a last-write-wins file adapter the
        # second one also overwrote the backup, losing the tick-9 city for good.
        assert :ok = @adapter.save(@city_id, 9, CityMap.new(19, 19))
        assert :ok = @adapter.save(@city_id, 0, CityMap.new(40, 30))
        assert :ok = @adapter.save(@city_id, 0, CityMap.new(40, 30))

        assert {:ok, {9, loaded}} = @adapter.load(@city_id)
        assert loaded.width == 19
      end

      test "load/1 does not see another city's snapshot" do
        assert :ok = @adapter.save("city-a", 5, CityMap.new(12, 12))

        assert {:error, :not_found} = @adapter.load("city-b")
      end

      test "save/3 overwrites the same city rather than accumulating" do
        assert :ok = @adapter.save(@city_id, 1, CityMap.new(11, 11))
        assert :ok = @adapter.save(@city_id, 2, CityMap.new(12, 12))

        assert {:ok, {2, loaded}} = @adapter.load(@city_id)
        assert loaded.width == 12
      end
    end
  end
end
