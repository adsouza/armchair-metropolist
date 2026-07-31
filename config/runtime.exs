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
# ARMCHAIR_DESKTOP is injected by the Tauri host only (see src-tauri/src/main.rs),
# so a plain `mix phx.server` or `mix test` run is unaffected.
#
# The desktop overrides themselves are deliberately NOT here. They live in
# `ArmchairMetropolist.Infrastructure.Desktop.Config.apply!/0`, called from
# `Application.start/2`, for two reasons: it is reachable by unit tests, where a
# config file is not, and it is one definition rather than two that can drift.
# This file only needs to know that a desktop boot has different *requirements*
# — see the `not desktop?` guard on the production block below.
desktop? = System.get_env("ARMCHAIR_DESKTOP") in ~w(1 true)

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

  # TLS, verifying the server against a pinned CA.
  #
  # Not `ssl: true`: Gigalixir's managed Postgres presents a certificate signed by
  # their own root (`O=Gigalixir, CN=Gigalixir CA`, self-signed, valid to 2057),
  # and since postgrex 0.18 `ssl: true` verifies against the OS trust store — which
  # that chain fails with `self-signed certificate in certificate chain`. So the CA
  # is pinned instead. `priv/cert/gigalixir-ca.pem` is public material, presented in
  # every handshake; it is not a secret and is safe in a public repository.
  #
  # `verify_peer` rather than the `verify_none` commonly pasted into Gigalixir
  # guides: the credentials and every row cross a network we do not control, and
  # verification demonstrably works here (checked with `openssl s_client -starttls
  # postgres` and a `sslmode=verify-full` connection), so switching it off would be
  # a choice rather than a constraint.
  #
  # DATABASE_SSL_CACERTFILE overrides the path if Gigalixir ever rotates that root;
  # DATABASE_SSL=false disables TLS entirely, for a local or sidecar Postgres that
  # does not offer it.
  ssl_opts =
    if System.get_env("DATABASE_SSL") in ~w(false 0) do
      false
    else
      cacertfile =
        System.get_env("DATABASE_SSL_CACERTFILE") ||
          Path.join(:code.priv_dir(:armchair_metropolist), "cert/gigalixir-ca.pem")

      File.exists?(cacertfile) ||
        raise """
        the CA certificate for the database was not found at:
            #{cacertfile}
        Set DATABASE_SSL_CACERTFILE to its location, or DATABASE_SSL=false if this
        deployment's Postgres does not offer TLS.
        """

      [
        verify: :verify_peer,
        cacertfile: cacertfile,
        # Erlang's :ssl does not check the hostname against the certificate unless
        # told how; without this, verify_peer would accept any cert this CA signed.
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    end

  config :armchair_metropolist, ArmchairMetropolist.Infrastructure.Persistence.Repo,
    ssl: ssl_opts,
    url: database_url,
    # 2, not the generated default of 10. Measured: the Gigalixir free-tier role
    # has `rolconnlimit = 4`, so a pool of 10 cannot open and the app fails to boot
    # on "too many connections for role". 2 leaves room for a second instance
    # during a rolling deploy and for `Release.migrate/0`, which opens its own.
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "2"),
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
