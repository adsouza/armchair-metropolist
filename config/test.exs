import Config

# The engine and the clock are singletons registered under their module names,
# and the engine hydrates from the database outside the Ecto sandbox. Tests
# start their own instances with `start_supervised!/1` and inject stub adapters,
# so the application must not start them itself.
config :armchair_metropolist, start_simulation: false

# The reaper is driven directly in tests via sweep/0; an interval this long keeps its
# timer from firing during a run.
config :armchair_metropolist, start_reaper: false

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :armchair_metropolist, ArmchairMetropolist.Infrastructure.Persistence.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "armchair_metropolist_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :armchair_metropolist, ArmchairMetropolistWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Ei9PQF33saYwhUwh9FlqQq7Qdla8cCT8mskYvDjSNpbh9MrV5tcT+vhGECa79xEg",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
