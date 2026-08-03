defmodule ArmchairMetropolist.Infrastructure.Persistence.SnapshotStoreTest do
  use ArmchairMetropolist.DataCase, async: false

  alias ArmchairMetropolist.Infrastructure.Persistence.{CitySnapshot, Repo, SnapshotStore}

  use ArmchairMetropolist.SnapshotRepositoryContract, adapter: SnapshotStore

  test "re-saving the same city at the same tick still returns the latest content" do
    # There is one row per city_id, so a second save at the same tick upserts
    # rather than creating a second, order-ambiguous row.
    :ok = SnapshotStore.save(@city_id, 5, CityMap.new(11, 11))
    :ok = SnapshotStore.save(@city_id, 5, CityMap.new(22, 22))

    assert {:ok, {5, loaded}} = SnapshotStore.load(@city_id)
    assert loaded.width == 22, "the later save at the same tick must win"
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
