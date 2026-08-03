defmodule ArmchairMetropolist.Infrastructure.Persistence.Repo.Migrations.CityScopedSnapshots do
  use Ecto.Migration

  # The single anonymous city this table has held until now is preserved rather than
  # dropped, so whatever has been built on the deployed instance stays reachable at
  # /c/legacy0000000000000000. Highest tick wins, with `id` breaking ties — exactly
  # the ordering the old `load_latest/0` used, so the row that survives is the one
  # that would have loaded.
  #
  # Not the plain word "legacy": CityCode's allowlist requires exactly 22
  # `[A-Za-z0-9_-]` characters (`city_code.ex`), and "legacy" is 6. A code that
  # fails that check never reaches `put_session/3` — city_controller.ex's `enter/2`
  # 404s instead — so the plain word would make the "preserved" city unreachable at
  # the very route this comment claims serves it. Padded with sixteen `0`s to reach
  # 22 characters exactly; verified with `CityCode.valid?/1` rather than by counting.
  @legacy_city_id "legacy0000000000000000"

  def up do
    create table(:city_snapshots_new, primary_key: false) do
      add :city_id, :string, primary_key: true
      add :tick, :integer, null: false
      add :payload, :binary, null: false
      add :checksum, :string, null: false

      timestamps()
    end

    # updated_at is set to this migration's own run time rather than copied from the
    # old row. The reaper (snapshot_reaper.ex) sweeps on updated_at, and copying a
    # possibly-ancient timestamp would start the preserved city's retention clock
    # already expired — the first sweep after this deploy would delete the very row
    # this migration exists to keep reachable. inserted_at is still copied: it is
    # the city's real creation time and the reaper does not read it.
    execute """
    INSERT INTO city_snapshots_new (city_id, tick, payload, checksum, inserted_at, updated_at)
    SELECT '#{@legacy_city_id}', tick, payload, checksum, inserted_at, (NOW() AT TIME ZONE 'utc')
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
    # Destructive, not merely lossy: the old shape has no city_id column, so rolling
    # back keeps only the single highest-tick city and discards every other visitor's
    # city outright — there is no way to fold many cities into one row without
    # throwing the rest away. `LIMIT 1` is what makes that explicit rather than
    # accidental: without it, every city's rows would land in city_snapshots_old at
    # once, and the old schema's `order_by: [desc: tick]` with no city scope would
    # then read whichever of them happens to have the highest tick, silently
    # discarding the other visitors' work with no signal that it happened. Rolling
    # back this migration is a one-way trip once more than one city exists; it exists
    # for the deploy window before that is true, not as a general escape hatch.
    create table(:city_snapshots_old) do
      add :tick, :integer, null: false
      add :payload, :binary, null: false
      add :checksum, :string, null: false

      timestamps()
    end

    execute """
    INSERT INTO city_snapshots_old (tick, payload, checksum, inserted_at, updated_at)
    SELECT tick, payload, checksum, inserted_at, updated_at FROM city_snapshots
    ORDER BY tick DESC
    LIMIT 1
    """

    drop table(:city_snapshots)
    rename table(:city_snapshots_old), to: table(:city_snapshots)
    create index(:city_snapshots, [:tick], name: :city_snapshots_tick_index)
  end
end
