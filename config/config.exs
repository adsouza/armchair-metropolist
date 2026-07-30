# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# The desktop wrapper. `app_name` also decides where ExTauri.Paths puts the
# snapshot file, so renaming it strands an existing city.
#
# `dev_command` is the sidecar `mix ex_tauri.dev` execs. ARMCHAIR_DESKTOP is what
# distinguishes the desktop boot from a plain `mix phx.server`: config/runtime.exs
# keys the desktop overrides off it, so the web target stays untouched.
config :ex_tauri,
  version: "2.5.1",
  app_name: "Armchair Metropolist",
  host: "localhost",
  port: 4000,
  window_title: "Armchair Metropolist",
  width: 1280,
  height: 900,
  resize: true,
  dev_command: ~w(env ARMCHAIR_DESKTOP=1 mix phx.server),
  sidecar_env: [
    {"PHX_SERVER", "true"},
    {"PHX_HOST", "localhost"},
    {"ARMCHAIR_DESKTOP", "1"}
  ]

config :armchair_metropolist,
  ecto_repos: [ArmchairMetropolist.Infrastructure.Persistence.Repo],
  generators: [timestamp_type: :utc_datetime]

config :armchair_metropolist,
  snapshot_repository: ArmchairMetropolist.Infrastructure.Persistence.SnapshotStore,
  notifier: ArmchairMetropolist.Infrastructure.Desktop.LogNotifier,
  grid_width: 40,
  grid_height: 30,
  tick_interval_ms: 1000,
  checkpoint_every_ticks: 50

# Configure the endpoint
config :armchair_metropolist, ArmchairMetropolistWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ArmchairMetropolistWeb.ErrorHTML, json: ArmchairMetropolistWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ArmchairMetropolist.PubSub,
  live_view: [signing_salt: "31UlmJwU"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  armchair_metropolist: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  armchair_metropolist: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
