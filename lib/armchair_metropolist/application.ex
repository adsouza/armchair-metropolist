defmodule ArmchairMetropolist.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ArmchairMetropolistWeb.Telemetry,
      ArmchairMetropolist.Repo,
      {DNSCluster, query: Application.get_env(:armchair_metropolist, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ArmchairMetropolist.PubSub},
      # Start a worker by calling: ArmchairMetropolist.Worker.start_link(arg)
      # {ArmchairMetropolist.Worker, arg},
      # Start to serve requests, typically the last entry
      ArmchairMetropolistWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ArmchairMetropolist.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ArmchairMetropolistWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
