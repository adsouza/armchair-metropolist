defmodule ArmchairMetropolist.Infrastructure.Persistence.Repo.Migrations.CreateCitySnapshots do
  use Ecto.Migration

  def change do
    create table(:city_snapshots) do
      add :tick, :integer, null: false
      add :payload, :binary, null: false
      add :checksum, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:city_snapshots, [:tick], name: :city_snapshots_tick_index)
  end
end
