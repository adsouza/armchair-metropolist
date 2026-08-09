defmodule ArmchairMetropolist.Infrastructure.Persistence.FileSnapshotStoreTest do
  use ExUnit.Case, async: false

  alias ArmchairMetropolist.Infrastructure.Persistence.FileSnapshotStore
  alias ArmchairMetropolist.Domain.Entities.MunicipalBond

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

  describe "I/O failures" do
    # The port declares `:ok | {:error, term()}` and CityEngine has a branch for
    # the error. While this adapter used File.write!/File.rename! that branch was
    # unreachable: a read-only snapshot directory raised inside handle_info/2, the
    # engine was restarted, and its state rolled back to the previous checkpoint.
    test "save_current/2 returns an error rather than raising when the directory is unwritable",
         %{dir: dir} do
      File.chmod!(dir, 0o500)
      on_exit(fn -> File.chmod!(dir, 0o700) end)

      assert {:error, reason} =
               FileSnapshotStore.save_current({1, 0}, at_order(sample_city(), 1))

      assert reason == :eacces
    end

    test "an unwritable directory does not damage the snapshot already stored",
         %{dir: dir} do
      :ok = FileSnapshotStore.save_current({4, 0}, at_order(sample_city(), 4))

      File.chmod!(dir, 0o500)
      on_exit(fn -> File.chmod!(dir, 0o700) end)

      assert {:error, :eacces} =
               FileSnapshotStore.save_current({5, 0}, at_order(CityMap.new(12, 12), 5))

      File.chmod!(dir, 0o700)
      assert {:ok, {{4, 0}, recovered}} = FileSnapshotStore.load_current()
      assert recovered == at_order(sample_city(), 4)
    end
  end

  test "load_current/0 hydrates a snapshot written before the transit-hub rename", %{dir: dir} do
    # Before the vocabulary shim this was the desktop's silent-loss path: the
    # retired atom made safe_binary_to_term/1 rescue to :malformed, load
    # reported :not_found, and the engine started a fresh city while the stale
    # file's higher envelope tick blocked every save (docs/deploying.md). The
    # envelope is built here with current atoms on purpose — only the *city*
    # payload inside it predates the rename, exactly as on a real install.
    payload = File.read!("test/support/fixtures/city_snapshot_pre_transit_hub_rename.bin")

    envelope = %{
      version: 1,
      tick: 283,
      checksum: :crypto.hash(:md5, payload) |> Base.encode16(),
      payload: payload
    }

    File.write!(Path.join(dir, "snapshot.bin"), :erlang.term_to_binary(envelope))

    assert {:ok, {{283, 0}, city}} = FileSnapshotStore.load_current()
    assert city.nodes["19:12"].type == :transit_hub
  end

  test "load_current/0 prefers the backup when it holds the higher tick", %{dir: dir} do
    # Reachable whenever a save lands out of order, and the reason load_current/0
    # cannot simply trust the primary.
    :ok = FileSnapshotStore.save_current({2, 0}, at_order(CityMap.new(12, 12), 2))
    :ok = FileSnapshotStore.save_current({3, 0}, at_order(CityMap.new(13, 13), 3))
    # Demote by hand: swap the two files, so the primary now holds the older tick.
    swap(Path.join(dir, "snapshot.bin"), Path.join(dir, "snapshot.bak"))

    assert {:ok, {{3, 0}, loaded}} = FileSnapshotStore.load_current()
    assert loaded.width == 13
  end

  test "re-saving the same tick overwrites in place", %{dir: dir} do
    :ok = FileSnapshotStore.save_current({5, 0}, at_order(CityMap.new(12, 12), 5))
    :ok = FileSnapshotStore.save_current({5, 0}, at_order(CityMap.new(14, 14), 5))

    assert {:ok, {{5, 0}, loaded}} = FileSnapshotStore.load_current()
    assert loaded.width == 14
    assert File.exists?(Path.join(dir, "snapshot.bak"))
  end

  test "an unconfigured :snapshot_dir fails with an actionable message" do
    prev = Application.get_env(:armchair_metropolist, :snapshot_dir)
    Application.delete_env(:armchair_metropolist, :snapshot_dir)
    on_exit(fn -> Application.put_env(:armchair_metropolist, :snapshot_dir, prev) end)

    # Previously this surfaced as a FunctionClauseError from Path.join(nil, _),
    # which names neither the setting nor where to set it.
    err = assert_raise ArgumentError, fn -> FileSnapshotStore.load_current() end
    assert err.message =~ ":snapshot_dir"
    assert err.message =~ "config/runtime.exs"
  end

  test "leaves no temp file behind after a successful save", %{dir: dir} do
    :ok = FileSnapshotStore.save_current({1, 0}, at_order(sample_city(), 1))
    refute File.exists?(Path.join(dir, "snapshot.tmp"))
    assert File.exists?(Path.join(dir, "snapshot.bin"))
  end

  test "falls back to the backup when the primary is corrupt", %{dir: dir} do
    :ok = FileSnapshotStore.save_current({1, 0}, at_order(sample_city(), 1))
    :ok = FileSnapshotStore.save_current({2, 0}, at_order(CityMap.new(12, 12), 2))

    File.write!(Path.join(dir, "snapshot.bin"), "garbage")

    assert {:ok, {{1, 0}, recovered}} = FileSnapshotStore.load_current()
    assert recovered == at_order(sample_city(), 1)
  end

  test "returns :not_found when both files are unusable", %{dir: dir} do
    :ok = FileSnapshotStore.save_current({1, 0}, at_order(sample_city(), 1))
    :ok = FileSnapshotStore.save_current({2, 0}, at_order(CityMap.new(12, 12), 2))
    File.write!(Path.join(dir, "snapshot.bin"), "garbage")
    File.write!(Path.join(dir, "snapshot.bak"), "also garbage")

    assert {:error, :not_found} = FileSnapshotStore.load_current()
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
    :ok = FileSnapshotStore.save_current({city.tick, city.revision}, city)

    {output, status} =
      System.cmd("elixir", ["-e", cold_load_script(dir)],
        env: [{"ERL_LIBS", Path.expand("_build/#{Mix.env()}/lib")}],
        stderr_to_stdout: true
      )

    output = String.trim(output)

    assert status == 0, "cold VM exited #{status}:\n#{output}"

    refute output =~ "VACUOUS",
           "the entity modules were already loaded, so this test proves nothing:\n#{output}"

    assert output == "OK tick=137 revision=9 nodes=7 w=17 h=11",
           "cold-VM load lost the city: #{output}"
  end

  defp swap(a, b) do
    scratch = a <> ".swap"
    File.rename!(a, scratch)
    File.rename!(b, a)
    File.rename!(scratch, b)
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

    %{
      city
      | tick: 137,
        revision: 9,
        municipal_bond: %MunicipalBond{
          original_principal: 400.0,
          outstanding_principal: 321.0,
          interest_arrears: 4.25,
          principal_arrears: 8.0,
          started_at_tick: 2
        }
    }
  end

  # Runs in a fresh VM. It must never mention a node type, a status, or any other
  # atom the payload carries — naming one here interns it and makes the test
  # vacuous. Only the tick, the node count and the dimensions are asserted on.
  defp cold_load_script(dir) do
    """
    Application.put_env(:armchair_metropolist, :snapshot_dir, #{inspect(dir)})

    entities = [
      ArmchairMetropolist.Domain.Entities.CityMap,
      ArmchairMetropolist.Domain.Entities.MunicipalBond,
      ArmchairMetropolist.Domain.Entities.Node
    ]

    already_loaded = Enum.filter(entities, &:code.is_loaded/1)

    if already_loaded != [] do
      IO.puts("VACUOUS \#{inspect(already_loaded)}")
    else
      case ArmchairMetropolist.Infrastructure.Persistence.FileSnapshotStore.load_current() do
        {:ok, {{tick, revision}, city}} ->
          IO.puts("OK tick=\#{tick} revision=\#{revision} nodes=\#{map_size(city.nodes)} w=\#{city.width} h=\#{city.height}")

        other ->
          IO.puts("FAIL \#{inspect(other)}")
      end
    end
    """
  end
end
