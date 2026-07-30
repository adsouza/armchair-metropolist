import Config

# `cache_static_manifest` is deliberately absent. The :desktop release is a :prod
# build assembled by `mix ex_tauri.build`, which does not run `mix assets.deploy`,
# so there is no priv/static/cache_manifest.json — and Phoenix raises at boot when
# the configured manifest is missing. Restore this line together with an
# `assets.deploy` step if a server deployment is ever added:
#
#     config :armchair_metropolist, ArmchairMetropolistWeb.Endpoint,
#       cache_static_manifest: "priv/static/cache_manifest.json"

# Force using SSL in production. This also sets the "strict-security-transport" header,
# known as HSTS. If you have a health check endpoint, you may want to exclude it below.
# Note `:force_ssl` is required to be set at compile-time.
config :armchair_metropolist, ArmchairMetropolistWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      # paths: ["/health"],
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
