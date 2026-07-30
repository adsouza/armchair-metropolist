defmodule ArmchairMetropolist.Infrastructure.Persistence.CitySnapshot do
  @moduledoc "Ecto schema for a persisted city snapshot."

  use Ecto.Schema
  import Ecto.Changeset

  schema "city_snapshots" do
    field :tick, :integer
    field :payload, :binary
    field :checksum, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(city_snapshot, attrs) do
    city_snapshot
    |> cast(attrs, [:tick, :payload, :checksum])
    |> validate_required([:tick, :payload, :checksum])
  end
end
