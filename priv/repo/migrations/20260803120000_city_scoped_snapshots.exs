defmodule ArmchairMetropolist.Infrastructure.Persistence.Repo.Migrations.CityScopedSnapshots do
  use Ecto.Migration

  # The single anonymous city this table has held until now is preserved rather than
  # dropped, so whatever has been built on the deployed instance stays reachable at
  # /c/legacy. Highest tick wins, with `id` breaking ties — exactly the ordering the
  # old `load_latest/0` used, so the row that survives is the one that would have
  # loaded.
  @legacy_city_id "legacy"

  def up do
    create table(:city_snapshots_new, primary_key: false) do
      add :city_id, :string, primary_key: true
      add :tick, :integer, null: false
      add :payload, :binary, null: false
      add :checksum, :string, null: false

      timestamps()
    end

    execute """
    INSERT INTO city_snapshots_new (city_id, tick, payload, checksum, inserted_at, updated_at)
    SELECT '#{@legacy_city_id}', tick, payload, checksum, inserted_at, updated_at
    FROM city_snapshots
    ORDER BY tick DESC, id DESC
    LIMIT 1
    """

    drop table(:city_snapshots)
    rename table(:city_snapshots_new), to: table(:city_snapshots)

    # `rename table/2` does not rename the implicit primary-key constraint, so without
    # this the schema carries `city_snapshots_new_pkey` forever — an artefact of how this
    # migration was built rather than anything about the table. Single-argument `execute/1`
    # rather than `execute/2`: this migration defines an explicit `down/0` rather than
    # `change/0`, so Ecto never runs `up/0` in reverse and a rollback string here would
    # never fire. `down/0` doesn't need one either — it builds `city_snapshots_old` fresh,
    # which gets its own default constraint name.
    execute "ALTER TABLE city_snapshots RENAME CONSTRAINT city_snapshots_new_pkey TO city_snapshots_pkey"

    # The reaper sweeps on this column (§8).
    create index(:city_snapshots, [:updated_at])
  end

  def down do
    # Honest about what it can restore: the history is gone, so rolling back yields
    # the old shape holding the one surviving city. Nothing that read the old table
    # depended on there being more than one row.
    create table(:city_snapshots_old) do
      add :tick, :integer, null: false
      add :payload, :binary, null: false
      add :checksum, :string, null: false

      timestamps()
    end

    execute """
    INSERT INTO city_snapshots_old (tick, payload, checksum, inserted_at, updated_at)
    SELECT tick, payload, checksum, inserted_at, updated_at FROM city_snapshots
    """

    drop table(:city_snapshots)
    rename table(:city_snapshots_old), to: table(:city_snapshots)
    create index(:city_snapshots, [:tick], name: :city_snapshots_tick_index)
  end
end
