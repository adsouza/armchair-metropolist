defmodule ArmchairMetropolist.Infrastructure.Persistence.SnapshotStoreTest do
  use ArmchairMetropolist.DataCase, async: false

  alias ArmchairMetropolist.Infrastructure.Persistence.{CitySnapshot, Repo, SnapshotStore}

  use ArmchairMetropolist.SnapshotRepositoryContract, adapter: SnapshotStore

  test "detects a corrupted payload" do
    :ok = SnapshotStore.save(1, sample_city())

    Repo.one(CitySnapshot)
    |> Ecto.Changeset.change(checksum: "DEADBEEF")
    |> Repo.update!()

    assert {:error, :checksum_mismatch} = SnapshotStore.load_latest()
  end
end
