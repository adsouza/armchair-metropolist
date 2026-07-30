import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/armchair_metropolist start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :armchair_metropolist, ArmchairMetropolistWeb.Endpoint, server: true
end

config :armchair_metropolist, ArmchairMetropolistWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# ## Desktop target
#
# Set by the Tauri sidecar only (`config :ex_tauri, :dev_command` in dev,
# `:sidecar_env` in a release), so a plain `mix phx.server` or `mix test` run is
# unaffected. The desktop build has no Postgres to talk to: the city lives in a
# file under the OS application-data directory instead, and alerts go to the
# native notification centre.
#
# Resolving the directory here — rather than inside FileSnapshotStore — is what
# keeps the persistence adapter free of any ExTauri reference. `data_dir/0`
# creates the directory, so the adapter's first write always has somewhere to go.
desktop? = System.get_env("ARMCHAIR_DESKTOP") in ~w(1 true)

if desktop? do
  config :armchair_metropolist,
    start_repo: false,
    start_shutdown_manager: true,
    snapshot_repository: ArmchairMetropolist.Infrastructure.Persistence.FileSnapshotStore,
    notifier: ArmchairMetropolist.Infrastructure.Desktop.TauriNotifier,
    snapshot_dir: ExTauri.Paths.data_dir()

  # The snapshot-on-shutdown guarantee is on a stopwatch here, and it is not ours.
  # Closing the window runs ExTauri's `kill_sidecar`: SIGTERM, poll for 2 seconds,
  # then SIGKILL. Children stop in reverse order, so the Endpoint stops before the
  # engine — and Thousand Island's default `shutdown_timeout` is 15 seconds of
  # waiting for open connections to drain. The Tauri window *is* one of those
  # connections (a LiveView socket), so the drain reliably outlasts the 2-second
  # budget and SIGKILL lands before CityEngine.terminate/2 ever runs. Measured: 8s
  # to the snapshot write with the default, ~0.3s with this.
  #
  # A local single-user window has nothing to drain gracefully for. The server
  # target keeps the full 15 seconds.
  config :armchair_metropolist, ArmchairMetropolistWeb.Endpoint,
    http: [thousand_island_options: [shutdown_timeout: 100]]

  # A :prod desktop release has no config/dev.exs default to fall back on. The
  # Tauri host always injects SECRET_KEY_BASE (a fresh per-launch value unless the
  # environment supplies one), which is all a single-user local app needs.
  if config_env() == :prod do
    config :armchair_metropolist, ArmchairMetropolistWeb.Endpoint,
      secret_key_base:
        System.get_env("SECRET_KEY_BASE") ||
          raise("the desktop release expects SECRET_KEY_BASE from the Tauri host")
  end
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :armchair_metropolist, ArmchairMetropolistWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/armchair_metropolist_web/router\.ex$"E,
        ~r"lib/armchair_metropolist_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

# The desktop release is a :prod build with no database and no deployment host,
# so it must not be held to the server deployment's required environment. Every
# other :prod boot still fails loudly on a missing DATABASE_URL or
# SECRET_KEY_BASE.
if config_env() == :prod and not desktop? do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :armchair_metropolist, ArmchairMetropolist.Infrastructure.Persistence.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :armchair_metropolist, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :armchair_metropolist, ArmchairMetropolistWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :armchair_metropolist, ArmchairMetropolistWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :armchair_metropolist, ArmchairMetropolistWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
