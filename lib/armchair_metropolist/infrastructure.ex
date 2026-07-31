defmodule ArmchairMetropolist.Infrastructure do
  use Boundary,
    deps: [
      ArmchairMetropolist.Domain,
      ArmchairMetropolist.UseCases,
      Ecto,
      Ecto.Query,
      Ecto.Changeset,
      Ecto.Schema,
      Ecto.Adapters.Postgres,
      Ecto.Adapters.SQL,
      Phoenix.PubSub,
      ExTauri
    ],
    exports: [Simulation.CityEngine, Persistence.Repo, Desktop.Config]
end
