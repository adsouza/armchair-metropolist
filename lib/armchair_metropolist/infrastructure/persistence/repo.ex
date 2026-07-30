defmodule ArmchairMetropolist.Infrastructure.Persistence.Repo do
  use Ecto.Repo,
    otp_app: :armchair_metropolist,
    adapter: Ecto.Adapters.Postgres
end
