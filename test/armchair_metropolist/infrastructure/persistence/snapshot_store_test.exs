defmodule ArmchairMetropolist.Infrastructure.Persistence.SnapshotStoreTest do
  use ArmchairMetropolist.DataCase, async: false

  alias ArmchairMetropolist.Infrastructure.Persistence.{CitySnapshot, Repo, SnapshotStore}

  use ArmchairMetropolist.SnapshotRepositoryContract, adapter: SnapshotStore

  test "load/1 does not see another city's snapshot" do
    assert :ok = SnapshotStore.save("city-a", {5, 0}, at_order(CityMap.new(12, 12), 5))

    assert {:error, :not_found} = SnapshotStore.load("city-b")
  end

  test "delete/1 does not remove another city's snapshot" do
    # The contract can't pin this: it only ever exercises one @city_id, and
    # FileSnapshotStore deliberately has no per-city scoping to test in the first
    # place. A delete/1 that forgot its `where: s.city_id == ^city_id` clause would
    # wipe every player's city, not just the one being reset.
    assert :ok = SnapshotStore.save("city-a", {5, 0}, at_order(CityMap.new(12, 12), 5))
    assert :ok = SnapshotStore.save("city-b", {5, 0}, at_order(CityMap.new(14, 14), 5))

    assert :ok = SnapshotStore.delete("city-a")

    assert {:error, :not_found} = SnapshotStore.load("city-a")
    assert {:ok, {{5, 0}, loaded}} = SnapshotStore.load("city-b")
    assert loaded.width == 14
  end

  test "load/1 hydrates a row stored before the transit-hub rename" do
    # A raw insert, not save/3: the point is a payload this code no longer
    # writes. The fixture is the row behind the 2026-08-05 production 500 —
    # before the vocabulary shim, decode/3 raised ArgumentError out of load/1
    # and the visitor's engine crash-looped.
    payload = File.read!("test/support/fixtures/city_snapshot_pre_transit_hub_rename.bin")
    checksum = :crypto.hash(:md5, payload) |> Base.encode16()

    %CitySnapshot{}
    |> CitySnapshot.changeset(%{
      city_id: @city_id,
      tick: 283,
      revision: 0,
      payload: payload,
      checksum: checksum
    })
    |> Repo.insert!()

    assert {:ok, {{283, 0}, city}} = SnapshotStore.load(@city_id)
    assert city.nodes["19:12"].type == :transit_hub
  end

  test "detects a corrupted payload" do
    :ok = SnapshotStore.save(@city_id, {1, 0}, at_order(sample_city(), 1))

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

    assert {:error, %Postgrex.Error{}} =
             SnapshotStore.save(@city_id, {1, 0}, at_order(sample_city(), 1))
  end

  test "save/3 rejects an ordering key that disagrees with the payload" do
    assert {:error, :snapshot_order_mismatch} =
             SnapshotStore.save(@city_id, {1, 0}, sample_city())
  end
end
