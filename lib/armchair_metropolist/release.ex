defmodule ArmchairMetropolist.Release do
  @moduledoc """
  Migration entry point for deployments where Mix does not exist.

  `mix ecto.migrate` cannot run against a release: Mix is not shipped inside one,
  so the task simply is not there on the deployed node. Gigalixir's
  `gigalixir ps:migrate` and its equivalents on other hosts call a module like
  this instead:

      bin/armchair_metropolist eval 'ArmchairMetropolist.Release.migrate()'

  `Ecto.Migrator.with_repo/2` starts the repo and the applications it needs, then
  stops them again, so this works from `eval` on a fresh unstarted node as well as
  alongside a running release. That matters here because `Application.start/2`
  starts no repo at all when `:start_repo` is false — the desktop target — and a
  migration must not depend on which target's child list happens to be in force.
  """

  use Boundary,
    top_level?: true,
    deps: [ArmchairMetropolist.Infrastructure, Ecto.Migrator]

  @app :armchair_metropolist

  @doc """
  Runs every pending migration, for each repo in `:ecto_repos`.
  """
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _result, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Rolls `repo` back to `version`. Deliberately requires both arguments: there is
  no sensible default for how far back to go.
  """
  @spec rollback(module(), integer()) :: :ok
  def rollback(repo, version) do
    load_app()

    {:ok, _result, _apps} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))

    :ok
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  # Loading, not starting: config must be readable before the repo is started, but
  # starting the application would boot the whole supervision tree — engine, clock
  # and endpoint included — which a migration has no business doing.
  defp load_app do
    Application.load(@app)
  end
end
