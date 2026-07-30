defmodule ArmchairMetropolist.MixProject do
  use Mix.Project

  def project do
    [
      app: :armchair_metropolist,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:boundary, :phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      test_coverage: [
        ignore_modules: [
          # Test scaffolding under test/support, not shipped code. Counting
          # these would measure how well the test helpers test themselves,
          # not how well the application is tested.
          ArmchairMetropolist.DataCase,
          ArmchairMetropolist.StubNotifier,
          ArmchairMetropolist.StubSnapshotRepository,
          ArmchairMetropolist.SlowSnapshotRepository,
          ArmchairMetropolist.CityGenerators,
          ArmchairMetropolist.SnapshotRepositoryContract,
          ArmchairMetropolist.SnapshotRepositoryOrderingContract
        ],
        # 70%, measured ~70.25% after closing the Task 12 gaps (desktop
        # notifiers, the place/4 guard-order test, SimulatorLive's
        # select_type handler). Domain, Domain.Services and UseCases are
        # pure and sit at 100% - this threshold must never be lowered to
        # paper over a regression there.
        #
        # The residual gap below 90% is concentrated in a handful of modules
        # that are mostly generated/declarative and not business logic:
        #   * ArmchairMetropolistWeb.CoreComponents (16.67%) - phx.new
        #     boilerplate UI components, most unused by this app's single
        #     LiveView page.
        #   * ArmchairMetropolistWeb (30.00%) - the `__using__` macros phx.new
        #     generates (:controller, :channel, :live_component, ...); only
        #     :live_view and :html are ever invoked here.
        #   * ArmchairMetropolistWeb.Router/.ErrorHTML/.Telemetry,
        #     ArmchairMetropolist.Application, .Infrastructure.Persistence.Repo
        #     and .SnapshotVocabulary - thin Phoenix/Ecto scaffolding whose
        #     uncovered lines are alternate boot-time branches (e.g. the
        #     desktop-vs-web child list) or generated helpers this app's
        #     tests never need to exercise directly.
        summary: [threshold: 70]
      ],
      boundary: [
        default: [
          check: [
            apps: [
              :ecto,
              :ecto_sql,
              :phoenix,
              :phoenix_live_view,
              :phoenix_pubsub,
              :postgrex,
              # Listed so the boundary compiler actually enforces the `ExTauri`
              # dep declarations: an external app absent from this list is
              # unchecked, and the desktop wrapper must stay reachable only from
              # the boundaries that opt into it.
              :ex_tauri,
              {:mix, :runtime}
            ]
          ]
        ]
      ],
      # `build_assets/1` must run before `:assemble`, which only *copies*
      # priv/static. The tailwind/esbuild output there is gitignored, so on a
      # clean checkout it does not exist and a release assembled without this
      # step would ship with no CSS and no JS.
      releases: [desktop: [steps: [&build_assets/1, :assemble]]]
    ]
  end

  # Reuses the `assets.build` alias rather than restating the tailwind/esbuild
  # invocations, so there is one definition to keep in step. Deliberately not
  # `assets.deploy`: that minifies (no benefit for assets served over localhost
  # to a webview, and unminified is easier to debug) and runs `phx.digest`,
  # whose cache_manifest.json nothing reads — `config/prod.exs` omits
  # `cache_static_manifest` on purpose.
  defp build_assets(%Mix.Release{} = release) do
    Mix.Task.run("assets.build")
    release
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {ArmchairMetropolist.Application, []},
      # :inets is required by the desktop target — Burrito's release wrapper and
      # ExTauri's updater both reach for :httpc at runtime.
      extra_applications: [:logger, :runtime_tools, :inets]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, check: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:boundary, "~> 0.10", runtime: false},
      {:stream_data, "~> 1.4", only: [:test]},
      {:ex_tauri, "~> 0.2"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind armchair_metropolist", "esbuild armchair_metropolist"],
      "assets.deploy": [
        "tailwind armchair_metropolist --minify",
        "esbuild armchair_metropolist --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      # The project's quality gate: a forced, warnings-as-errors recompile
      # (catches boundary violations too, since :boundary is in `compilers`)
      # followed by the full test suite under coverage instrumentation, which
      # enforces `test_coverage[:threshold]` above. `@tag :cold_vm` runs by
      # default (no `--exclude`) - it is a ~0.7s regression test for a real
      # data-loss bug (see file_snapshot_store_test.exs), fast enough that
      # excluding it from the gate would buy nothing.
      check: ["compile --force --warnings-as-errors", "test --cover"]
    ]
  end
end
