defmodule ArmchairMetropolist.Infrastructure.Persistence.FileSnapshotStoreTest do
  use ExUnit.Case, async: false

  alias ArmchairMetropolist.Infrastructure.Persistence.FileSnapshotStore

  setup do
    dir = Path.join(System.tmp_dir!(), "acm_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev = Application.get_env(:armchair_metropolist, :snapshot_dir)
    Application.put_env(:armchair_metropolist, :snapshot_dir, dir)

    on_exit(fn ->
      File.rm_rf!(dir)
      Application.put_env(:armchair_metropolist, :snapshot_dir, prev)
    end)

    {:ok, dir: dir}
  end

  use ArmchairMetropolist.SnapshotRepositoryContract, adapter: FileSnapshotStore

  test "leaves no temp file behind after a successful save", %{dir: dir} do
    :ok = FileSnapshotStore.save(1, sample_city())
    refute File.exists?(Path.join(dir, "snapshot.tmp"))
    assert File.exists?(Path.join(dir, "snapshot.bin"))
  end

  test "falls back to the backup when the primary is corrupt", %{dir: dir} do
    :ok = FileSnapshotStore.save(1, sample_city())
    :ok = FileSnapshotStore.save(2, CityMap.new(12, 12))

    File.write!(Path.join(dir, "snapshot.bin"), "garbage")

    assert {:ok, {1, recovered}} = FileSnapshotStore.load_latest()
    assert recovered == sample_city()
  end

  test "returns :not_found when both files are unusable", %{dir: dir} do
    :ok = FileSnapshotStore.save(1, sample_city())
    :ok = FileSnapshotStore.save(2, CityMap.new(12, 12))
    File.write!(Path.join(dir, "snapshot.bin"), "garbage")
    File.write!(Path.join(dir, "snapshot.bak"), "also garbage")

    assert {:error, :not_found} = FileSnapshotStore.load_latest()
  end
end
