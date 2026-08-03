defmodule ArmchairMetropolist.Infrastructure.Persistence.CitySnapshot do
  @moduledoc "Ecto schema for a persisted city snapshot."

  use Ecto.Schema
  import Ecto.Changeset

  # The city id is the key: one row per city, upserted. There is no surrogate id to
  # tie-break on any more because there are no ties.
  @primary_key {:city_id, :string, autogenerate: false}
  schema "city_snapshots" do
    field :tick, :integer
    field :payload, :binary
    field :checksum, :string

    timestamps()
  end

  @doc false
  def changeset(city_snapshot, attrs) do
    city_snapshot
    |> cast(attrs, [:city_id, :tick, :payload, :checksum])
    |> validate_required([:city_id, :tick, :payload, :checksum])
  end
end
