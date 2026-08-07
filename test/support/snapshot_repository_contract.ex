defmodule ArmchairMetropolist.SnapshotRepositoryContract do
  @moduledoc """
  Shared assertions every `SnapshotRepository` adapter must satisfy.

  `use` this from an adapter's test and it gains the whole contract. There is
  deliberately only one module to `use`: the ordering assertions below lived in a
  separate `SnapshotRepositoryOrderingContract` for a while, which meant a new
  adapter could `use` one and silently skip the other.

  ## On the ordering cases

  A save cannot move a city backwards: both adapters refuse a tick at or below
  what is already stored and say so with `{:stale, stored_tick}`, rather than
  silently keeping the newer content while reporting `:ok` as if the write had
  happened. That distinction is invisible while ticks only ever ascend, which is
  why the ascending-only "returns the most recent snapshot" case passes against
  both adapters without exercising the guarantee at all. The descending and
  equal-tick cases are what actually exercise it.

  ## What this contract is not

  It is a shape and a staleness guarantee, not a tenancy model. `FileSnapshotStore`
  ignores the city id and keeps exactly one pair of files, so per-city isolation is
  real for `SnapshotStore` and does not exist for `FileSnapshotStore` — asserting it
  here would be a false claim for one adapter, not a shared property with an
  adapter-specific wrinkle. It lives in `snapshot_store_test.exs` instead.

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

      test "save/3 refuses an older tick and says so" do
        assert :ok = @adapter.save(@city_id, 9, CityMap.new(19, 19))

        assert {:stale, 9} = @adapter.save(@city_id, 1, CityMap.new(11, 11))

        assert {:ok, {9, loaded}} = @adapter.load(@city_id)
        assert loaded.width == 19
      end

      test "save/3 refuses an equal tick, so a replay cannot rewrite a stored tick" do
        assert :ok = @adapter.save(@city_id, 5, CityMap.new(19, 19))

        assert {:stale, 5} = @adapter.save(@city_id, 5, CityMap.new(11, 11))

        assert {:ok, {5, loaded}} = @adapter.load(@city_id)
        assert loaded.width == 19
      end

      test "save/3 advances the same city rather than accumulating rows" do
        assert :ok = @adapter.save(@city_id, 1, CityMap.new(11, 11))
        assert :ok = @adapter.save(@city_id, 2, CityMap.new(12, 12))

        assert {:ok, {2, loaded}} = @adapter.load(@city_id)
        assert loaded.width == 12
      end

      test "delete/1 removes the stored city" do
        assert :ok = @adapter.save(@city_id, 7, sample_city())
        assert :ok = @adapter.delete(@city_id)
        assert {:error, :not_found} = @adapter.load(@city_id)
      end

      test "delete/1 is :ok when nothing is stored" do
        # A reset of a city that has never been checkpointed is ordinary, not an error.
        assert :ok = @adapter.delete(@city_id)
      end

      test "after delete/1 a lower tick can be saved again" do
        # The whole reason this callback exists. `save/3` is monotonic in tick, so a
        # city reset to tick 0 is unsaveable until it climbs back past what is stored —
        # during which a restart would restore the city the player just wiped.
        #
        # Two accepted saves, not one: on FileSnapshotStore the second creates a
        # backup file alongside the primary, and load_current/0 reads *both*,
        # returning whichever holds the higher tick. A delete/1 that only cleared
        # the primary would leave the backup to resurrect the wiped city on the
        # very next load — this is a shared property, not a file-adapter wrinkle,
        # since the same two-writes-then-delete sequence is what a real reset does
        # on either adapter.
        assert :ok = @adapter.save(@city_id, 8, CityMap.new(18, 18))
        assert :ok = @adapter.save(@city_id, 9, CityMap.new(19, 19))
        assert {:stale, 9} = @adapter.save(@city_id, 1, CityMap.new(11, 11))

        assert :ok = @adapter.delete(@city_id)
        assert {:error, :not_found} = @adapter.load(@city_id)

        assert :ok = @adapter.save(@city_id, 1, CityMap.new(11, 11))
        assert {:ok, {1, loaded}} = @adapter.load(@city_id)
        assert loaded.width == 11
      end
    end
  end
end
