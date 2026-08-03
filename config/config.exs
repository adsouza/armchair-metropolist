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
# ARMCHAIR_DESKTOP is what distinguishes the desktop boot from a plain
# `mix phx.server`: config/runtime.exs keys every desktop override off it, so the
# web target stays untouched. It reaches the sidecar by two separate routes:
#
#   * `dev_command` below — the shim `mix ex_tauri.dev` generates and execs.
#   * a literal in src-tauri/src/main.rs, which covers a Burrito release.
#
# `sidecar_env` below does NOT currently set it. That key is consumed only at
# install time, to generate main.rs, and our installer run predates it — so it is
# inert today and the hand-written literal in main.rs is what actually works. It is
# kept because it makes the patch self-healing: re-running `mix ex_tauri.install`
# overwrites main.rs from its template, and this key is what puts ARMCHAIR_DESKTOP
# back into the regenerated file.
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
  # How long an engine stays alive after its last viewer disconnects. A page reload
  # disconnects and reconnects within a second, so stopping immediately would make
  # every refresh pay a save, a process death, a restart and a hydrate.
  engine_linger_ms: 30_000,
  # How long an engine started by a dead render (SimulatorLive.do_mount/2 calls
  # CityEngine.snapshot/1 before connected?(socket) is true) stays alive if no live
  # mount ever attaches to it. Deliberately much shorter than engine_linger_ms
  # above: EnsureCityId hands every cookieless request its own city id, so without
  # a short bound here a crawler or scanner sustains one live, ticking engine per
  # request for the full post-viewer linger. The ordinary live mount that follows a
  # real dead render attaches within about a second, well inside this window.
  engine_unattached_linger_ms: 2_000,
  checkpoint_every_ticks: 50,
  # Cities nobody has opened in this long are deleted. Generous on purpose: someone
  # returning after months should still find their city, and one row per city means
  # storage is not the pressure here — unbounded retention of data keyed to a cookie is.
  snapshot_retention_days: 90,
  snapshot_sweep_interval_ms: 24 * 60 * 60 * 1000

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
