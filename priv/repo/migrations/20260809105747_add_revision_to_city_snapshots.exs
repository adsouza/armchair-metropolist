defmodule ArmchairMetropolist.Infrastructure.Persistence.Repo.Migrations.AddRevisionToCitySnapshots do
  use Ecto.Migration

  def change do
    alter table(:city_snapshots) do
      add :revision, :integer, null: false, default: 0
    end
  end
end
