defmodule ArmchairMetropolist.Infrastructure.Persistence.SnapshotReaperTest do
  use ArmchairMetropolist.DataCase, async: false

  import ExUnit.CaptureLog

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

  # Named for what it actually checks, not more: 89 days against a 90-day window
  # is a full day - about 86,400 seconds - inside it, so this cannot distinguish
  # `<` from `<=` and does not probe the edge itself. Hitting `updated_at ==
  # cutoff` deterministically would need an injectable clock, which this module
  # does not have (`cutoff` is computed from a live `NaiveDateTime.utc_now()`
  # inside sweep/0); asserting a stale, wall-clock-dependent exact match would
  # be flaky rather than a real test, so this is deliberately a day short instead
  # of exactly at it.
  test "keeps a city comfortably inside the window, one day short of the cutoff" do
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

  # At days = 0, `-days * 86_400` and `+days * 86_400` are both zero, so this
  # cannot catch a sign-reversed cutoff - that bug is real and catastrophic (a
  # future cutoff makes every row look old), but it is the "deletes a city past
  # the window and keeps a fresh one" and "keeps a city comfortably inside the
  # window" tests above that catch it, by comparing two rows against a cutoff
  # that only lands between them when the sign is right. What this test alone
  # protects against is `<=` standing in for `<`: with days = 0, cutoff collapses
  # to "now", and a row saved a moment earlier has updated_at strictly before
  # that - so `<=` would delete it and `<` must not.
  test "a zero-day window still spares a city saved this instant" do
    Application.put_env(:armchair_metropolist, :snapshot_retention_days, 0)
    on_exit(fn -> Application.delete_env(:armchair_metropolist, :snapshot_retention_days) end)
    :ok = SnapshotStore.save("now", 1, CityMap.new(10, 10))

    assert {:ok, 0} = SnapshotReaper.sweep()
  end

  # The four tests above drive sweep/0 directly and never touch init/1,
  # handle_continue/2, handle_info/2 or schedule/1 - the module's actual design
  # ("sweeps once on boot and then every interval") lives entirely in those
  # callbacks. These start the real process instead.
  #
  # :sys.get_state/1 is the synchronisation tool throughout: it only replies
  # once the target process has drained its mailbox up to that point, and the
  # boot sweep runs via handle_continue before the process ever reaches its
  # receive loop - so calling it right after start_supervised!/1 blocks until
  # the boot sweep (success or failure) has actually happened.
  describe "the GenServer lifecycle" do
    test "sweeps once on boot, without anyone calling sweep/0" do
      :ok = SnapshotStore.save("boot-stale", 1, CityMap.new(10, 10))
      age("boot-stale", 91)

      pid = start_supervised!(SnapshotReaper)
      :sys.get_state(pid)

      assert {:error, :not_found} = SnapshotStore.load("boot-stale")
    end

    test "reschedules and sweeps again on the next interval" do
      Application.put_env(:armchair_metropolist, :snapshot_sweep_interval_ms, 20)

      on_exit(fn ->
        Application.delete_env(:armchair_metropolist, :snapshot_sweep_interval_ms)
      end)

      pid = start_supervised!(SnapshotReaper)
      # Boot sweep first, over an empty table - nothing to assert on yet, just
      # a checkpoint before the row below exists.
      :sys.get_state(pid)

      :ok = SnapshotStore.save("late-stale", 1, CityMap.new(10, 10))
      age("late-stale", 91)

      # No sys call can wait on a future timer message the way it waits on a
      # mailbox already holding one, so this polls instead of a single
      # synchronous check.
      wait_until(fn -> match?({:error, :not_found}, SnapshotStore.load("late-stale")) end)
    end

    # The regression test for the guard in safe_sweep/0: a failing sweep must
    # not crash the process, and the process must still be the one that
    # recovers on the next interval, not a supervisor restart standing in for
    # it.
    #
    # The failure is a bad :snapshot_retention_days rather than a broken table:
    # both reach the same rescue/catch in safe_sweep/0 (it is not specific to
    # database errors), and forcing a real Postgrex error would mean breaking
    # the `city_snapshots` table out from under the sandboxed connection this
    # test already shares - solvable, but it is more moving parts for the same
    # coverage of the thing actually under test, which is the guard, not
    # Postgres's error behaviour.
    test "a sweep that raises does not kill the process, and the next interval still fires" do
      Application.put_env(:armchair_metropolist, :snapshot_sweep_interval_ms, 20)
      Application.put_env(:armchair_metropolist, :snapshot_retention_days, :not_a_number)

      on_exit(fn ->
        Application.delete_env(:armchair_metropolist, :snapshot_sweep_interval_ms)
        Application.delete_env(:armchair_metropolist, :snapshot_retention_days)
      end)

      log =
        capture_log(fn ->
          pid = start_supervised!(SnapshotReaper)
          ref = Process.monitor(pid)

          # Blocks until the boot sweep - which raises ArithmeticError computing
          # `-days * 24 * 60 * 60` for an atom `days` - has been through
          # safe_sweep/0's rescue.
          :sys.get_state(pid)

          # Inside the capture rather than after it, and that is not tidiness. The
          # interval above is 20ms, so this 100ms window is another four failing
          # sweeps; left outside, their warnings printed to the console on every
          # `mix test` run. Four lines of "[reaper] sweep failed" from a *passing*
          # suite read exactly like a real fault, and on 2026-08-08 they were filed
          # as one - the investigation ended here, at a test doing precisely what it
          # says it does. Expected noise that looks like a failure has a cost, and
          # that is the cost.
          #
          # Keeping the monitor inside the block is what lets this move: `pid` and
          # `ref` used to be smuggled out through the process dictionary purely
          # because the assertion below needed them.
          refute_receive {:DOWN, ^ref, :process, ^pid, _reason},
                         100,
                         "a raise inside sweep/0 must not crash the reaper"
        end)

      assert log =~ "sweep failed", "the failure must be logged, not merely swallowed"

      # Heal the config and prove recovery comes from the *next scheduled*
      # sweep, not a restart: if schedule/1 were skipped after a failure (e.g.
      # guarding the whole handle_continue/handle_info body up to and including
      # the reschedule, rather than just the sweep call), this would time out.
      Application.put_env(:armchair_metropolist, :snapshot_retention_days, 90)

      :ok = SnapshotStore.save("recovers-after-failure", 1, CityMap.new(10, 10))
      age("recovers-after-failure", 91)

      wait_until(fn ->
        match?({:error, :not_found}, SnapshotStore.load("recovers-after-failure"))
      end)
    end
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() ->
        :ok

      attempts <= 0 ->
        flunk("condition was not met within the polling window")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end
end
