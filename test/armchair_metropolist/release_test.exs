defmodule ArmchairMetropolist.ReleaseTest do
  @moduledoc """
  Covers the deploy-time migration path, which nothing else exercises. `mix
  ecto.migrate` cannot run against a release — Mix is not shipped inside one — so
  if `Release.migrate/0` is broken the failure appears during a production deploy
  and nowhere earlier.

  `async: false`, and the sandbox is switched to `:auto` for the duration. Two
  reasons it cannot run sandboxed: DDL inside the sandbox's transaction would be
  rolled straight back, and `Ecto.Migrator` does its work in a `Task`, which is not
  the process that owns a checked-out connection. `:auto` is a global setting, so
  this must not overlap with anything — hence `async: false`.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias ArmchairMetropolist.Infrastructure.Persistence.Repo
  alias ArmchairMetropolist.Release

  setup do
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      # However this test exits, leave the database migrated and the sandbox as it
      # was found: a failure part-way through must not cascade into every other
      # test that needs the table.
      Release.migrate()
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  # This is the test that pins migrate/0's actual behaviour, because it is the only
  # one that starts from a database without the table. Asserting "migrate/0 creates
  # the table" against an already-migrated database proves nothing — it passes just
  # as well when migrate/0 does nothing at all, which is how this suite was first
  # written and why the mutation check caught it.
  test "migrate/0 creates the schema, and rollback/2 removes it again" do
    assert table_exists?("city_snapshots"), "precondition: the suite runs migrated"

    assert Release.rollback(Repo, 0) == :ok
    refute table_exists?("city_snapshots"), "rollback/2 must drop what it created"

    assert Release.migrate() == :ok
    assert table_exists?("city_snapshots"), "migrate/0 must restore the snapshot table"
  end

  # Narrower claim, honestly stated: only that a second run is harmless. A redeploy
  # runs migrate/0 against an already-migrated database every time, and this fails
  # if that raises rather than returning :ok.
  test "migrate/0 does not fail when there is nothing left to do" do
    assert Release.migrate() == :ok
    assert Release.migrate() == :ok
    assert table_exists?("city_snapshots")
  end

  defp table_exists?(name) do
    %{rows: [[exists?]]} =
      Repo.query!(
        "select exists (select 1 from information_schema.tables " <>
          "where table_schema = 'public' and table_name = $1)",
        [name]
      )

    exists?
  end
end
