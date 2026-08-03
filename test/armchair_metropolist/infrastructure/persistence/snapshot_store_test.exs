defmodule ArmchairMetropolist.Infrastructure.Persistence.SnapshotStoreTest do
  use ArmchairMetropolist.DataCase, async: false

  alias ArmchairMetropolist.Infrastructure.Persistence.{CitySnapshot, Repo, SnapshotStore}

  use ArmchairMetropolist.SnapshotRepositoryContract, adapter: SnapshotStore

  test "load/1 does not see another city's snapshot" do
    assert :ok = SnapshotStore.save("city-a", 5, CityMap.new(12, 12))

    assert {:error, :not_found} = SnapshotStore.load("city-b")
  end

  test "detects a corrupted payload" do
    :ok = SnapshotStore.save(@city_id, 1, sample_city())

    Repo.one(CitySnapshot)
    |> Ecto.Changeset.change(checksum: "DEADBEEF")
    |> Repo.update!()

    assert {:error, :checksum_mismatch} = SnapshotStore.load(@city_id)
  end

  test "save/3 returns an error rather than raising when the database rejects the write" do
    # Repo.insert/1 raises Postgrex.Error on a missing table, which used to escape
    # into CityEngine.handle_info/2 and restart the engine. The DROP is inside the
    # sandbox transaction, so it is rolled back when this test ends.
    Repo.query!("DROP TABLE city_snapshots")

    assert {:error, %Postgrex.Error{}} = SnapshotStore.save(@city_id, 1, sample_city())
  end

  test "save/3 returns an error rather than raising when the changeset is invalid" do
    assert {:error, %Ecto.Changeset{valid?: false}} =
             SnapshotStore.save(@city_id, nil, sample_city())
  end
end
