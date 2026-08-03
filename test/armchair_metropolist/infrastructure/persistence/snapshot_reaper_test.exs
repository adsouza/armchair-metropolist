defmodule ArmchairMetropolist.Infrastructure.Persistence.SnapshotReaperTest do
  use ArmchairMetropolist.DataCase, async: false

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Infrastructure.Persistence.CitySnapshot
  alias ArmchairMetropolist.Infrastructure.Persistence.Repo
  alias ArmchairMetropolist.Infrastructure.Persistence.SnapshotReaper
  alias ArmchairMetropolist.Infrastructure.Persistence.SnapshotStore

  defp age(city_id, days) do
    stale = NaiveDateTime.utc_now() |> NaiveDateTime.add(-days * 86_400, :second)

    Repo.update_all(from(s in CitySnapshot, where: s.city_id == ^city_id),
      set: [updated_at: stale]
    )
  end

  test "deletes a city past the window and keeps a fresh one" do
    :ok = SnapshotStore.save("stale", 1, CityMap.new(10, 10))
    :ok = SnapshotStore.save("fresh", 1, CityMap.new(10, 10))
    age("stale", 91)

    assert {:ok, 1} = SnapshotReaper.sweep()
    assert {:error, :not_found} = SnapshotStore.load("stale")
    assert {:ok, _} = SnapshotStore.load("fresh")
  end

  test "keeps a city exactly at the boundary" do
    :ok = SnapshotStore.save("edge", 1, CityMap.new(10, 10))
    age("edge", 89)

    assert {:ok, 0} = SnapshotReaper.sweep()
    assert {:ok, _} = SnapshotStore.load("edge")
  end

  test "does not delete a city it has just seen" do
    :ok = SnapshotStore.save("new", 1, CityMap.new(10, 10))

    assert {:ok, 0} = SnapshotReaper.sweep()
    assert {:ok, _} = SnapshotStore.load("new")
  end

  test "a zero-day window still spares a city saved this instant" do
    Application.put_env(:armchair_metropolist, :snapshot_retention_days, 0)
    on_exit(fn -> Application.delete_env(:armchair_metropolist, :snapshot_retention_days) end)
    :ok = SnapshotStore.save("now", 1, CityMap.new(10, 10))

    assert {:ok, 0} = SnapshotReaper.sweep()
  end
end
