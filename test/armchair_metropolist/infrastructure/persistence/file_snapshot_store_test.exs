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

  # The regression test for the defect the desktop target exposed: `:safe` decoding
  # will not create atoms, and a stored city is made of them. On a cold VM — which
  # is exactly what the engine hydrates on — the entity modules are not loaded, so
  # those atoms do not exist and the decode raised, was rescued to `:malformed`, and
  # was folded into `:not_found`. A saved city discarded in silence.
  #
  # It cannot be caught in-process: this suite has already loaded CityMap and Node
  # by the time it runs, so every atom is interned and the decode always succeeds.
  # Only a genuinely fresh VM reproduces it, hence the `System.cmd`. ERL_LIBS gives
  # the child the code path without starting anything, so module loading stays lazy.
  #
  # Excluded with `--exclude cold_vm` where the _build layout differs.
  @tag :cold_vm
  test "a saved city survives being loaded by a cold VM", %{dir: dir} do
    city = maximal_city()
    :ok = FileSnapshotStore.save(city.tick, city)

    {output, status} =
      System.cmd("elixir", ["-e", cold_load_script(dir)],
        env: [{"ERL_LIBS", Path.expand("_build/#{Mix.env()}/lib")}],
        stderr_to_stdout: true
      )

    output = String.trim(output)

    assert status == 0, "cold VM exited #{status}:\n#{output}"

    refute output =~ "VACUOUS",
           "the entity modules were already loaded, so this test proves nothing:\n#{output}"

    assert output == "OK tick=137 nodes=7 w=17 h=11",
           "cold-VM load lost the city: #{output}"
  end

  # Deliberately maximal, so the atom coverage of @vocabulary is exercised in full:
  # every node type, every status, dimensions that are not the defaults, and a tick
  # that is not a multiple of the checkpoint interval.
  defp maximal_city do
    statuses = [:online, :degraded, :offline]
    healths = %{online: 88.0, degraded: 41.5, offline: 7.25}

    city =
      Node.types()
      |> Enum.with_index()
      |> Enum.reduce(CityMap.new(17, 11), fn {type, index}, acc ->
        status = Enum.at(statuses, rem(index, 3))
        node = %Node{Node.new(index, 0, type) | health: healths[status], status: status}
        CityMap.put_node(acc, node)
      end)

    %{city | tick: 137}
  end

  # Runs in a fresh VM. It must never mention a node type, a status, or any other
  # atom the payload carries — naming one here interns it and makes the test
  # vacuous. Only the tick, the node count and the dimensions are asserted on.
  defp cold_load_script(dir) do
    """
    Application.put_env(:armchair_metropolist, :snapshot_dir, #{inspect(dir)})

    entities = [
      ArmchairMetropolist.Domain.Entities.CityMap,
      ArmchairMetropolist.Domain.Entities.Node
    ]

    already_loaded = Enum.filter(entities, &:code.is_loaded/1)

    if already_loaded != [] do
      IO.puts("VACUOUS \#{inspect(already_loaded)}")
    else
      case ArmchairMetropolist.Infrastructure.Persistence.FileSnapshotStore.load_latest() do
        {:ok, {tick, city}} ->
          IO.puts("OK tick=\#{tick} nodes=\#{map_size(city.nodes)} w=\#{city.width} h=\#{city.height}")

        other ->
          IO.puts("FAIL \#{inspect(other)}")
      end
    end
    """
  end
end
