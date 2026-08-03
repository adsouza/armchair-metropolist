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
    exports: [Simulation.CityEngine, Simulation.CityRegistry, Persistence.Repo, Desktop.Config]
end
