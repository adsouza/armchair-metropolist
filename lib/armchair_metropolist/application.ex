defmodule ArmchairMetropolist.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  use Boundary,
    top_level?: true,
    deps: [
      ArmchairMetropolist.Domain,
      ArmchairMetropolist.Domain.Services,
      ArmchairMetropolist.UseCases,
      ArmchairMetropolist.Infrastructure,
      ArmchairMetropolistWeb,
      ExTauri
    ]

  @impl true
  def start(_type, _args) do
    # Children are assembled from config so a target can leave parts out: the
    # desktop build runs the file snapshot adapter and needs no Repo, and the
    # test run starts its own engine and clock per test.
    children =
      desktop_children() ++
        repo_children() ++
        [
          {DNSCluster,
           query: Application.get_env(:armchair_metropolist, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: ArmchairMetropolist.PubSub},
          ArmchairMetropolistWeb.Telemetry
        ] ++
        simulation_children() ++
        [
          # Serves requests, so it starts last.
          ArmchairMetropolistWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ArmchairMetropolist.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # `mix ex_tauri.install` could not place this child itself — it looks for a
  # literal `children = [...]` list and this tree is assembled from functions —
  # so it is wired up here by hand, behind the same style of config gate as the
  # rest of the tree.
  #
  # It goes first for two reasons: its heartbeat listener must exist before the
  # Rust frontend tries to connect, and starting first means terminating last,
  # so the shutdown it triggers outlives the engine's snapshot write.
  #
  # ShutdownManager reacts to heartbeat loss with `System.stop/1`, which runs the
  # ordinary application shutdown — that is what gets `CityEngine.terminate/2`,
  # and therefore the final snapshot, on window close.
  defp desktop_children do
    if Application.get_env(:armchair_metropolist, :start_shutdown_manager, false) do
      [ExTauri.ShutdownManager]
    else
      []
    end
  end

  defp repo_children do
    if Application.get_env(:armchair_metropolist, :start_repo, true) do
      [ArmchairMetropolist.Infrastructure.Persistence.Repo]
    else
      []
    end
  end

  # The engine is given a 10s shutdown budget: the 5s default can kill it
  # mid-write and lose the city it was persisting. The clock starts after the
  # engine so the first pulse has somewhere to land, but it never references the
  # engine — a dead engine must not be able to stall the clock.
  defp simulation_children do
    if Application.get_env(:armchair_metropolist, :start_simulation, true) do
      [
        Supervisor.child_spec(ArmchairMetropolist.Infrastructure.Simulation.CityEngine,
          shutdown: 10_000
        ),
        ArmchairMetropolist.Infrastructure.Simulation.TickServer
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ArmchairMetropolistWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
