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
        # 90%, measured 91.76%. This is the figure the design spec asked for
        # (section 9) and it became reachable only after deleting the unused
        # phx.new CoreComponents - 363 lines sitting at 16.67% coverage, which
        # alone held the honest threshold down to 70.
        #
        # Domain, Domain.Services and UseCases are pure and sit at 100%. Never
        # lower this to paper over a regression in those three.
        #
        # The residual gap is thin Phoenix/Ecto scaffolding whose uncovered
        # lines are alternate boot-time branches or generated helpers:
        #   * ArmchairMetropolistWeb (30%) - the __using__ macros phx.new
        #     generates (:controller, :channel, :live_component, ...); only
        #     :live_view and :html are ever invoked here.
        #   * SnapshotVocabulary (50%), ErrorHTML (50%), Router (75%),
        #     Application (77.78%), Telemetry (80%), TickServer (84.62%).
        #     Application's gap is the desktop-vs-web child list, which cannot
        #     both be taken in one run.
        summary: [threshold: 90]
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
      #
      # `&Burrito.wrap/1` turns the assembled release into a single-file
      # executable per target. It requires Zig on PATH — Burrito shells out to
      # `zig build` for every build, native included, despite ex_tauri's docs
      # claiming Zig is cross-compilation-only.
      releases: [
        desktop: [
          steps: [&build_assets/1, :assemble, &Burrito.wrap/1],
          burrito: [targets: burrito_targets()]
        ]
      ]
    ]
  end

  # Burrito swaps the release's ERTS for a prebuilt one from the
  # beam-machine-universal CDN, and by default asks for the *build machine's*
  # OTP version. This machine runs 29.0.4, which the CDN has not built — 404 on
  # macOS and both Linux arches. Pinning `custom_erts` to 29.0.3 fixes that
  # without touching the local toolchain: same OTP major/minor, so the compiled
  # BEAM is compatible, and no downgrade of a working dev environment.
  #
  # Verified by probe: 29.0.3 returns 200 on all three targets below, as does
  # 28.4.2. 29.0.3 is preferred — one patch back rather than a major downgrade.
  # Re-probe before a release; once the CDN builds 29.0.4 these can be dropped
  # and Burrito's default will be correct again.
  #
  # Note `ex_tauri`'s docs claim Zig is needed only for cross-compilation; that
  # is wrong — Burrito shells out to `zig build` unconditionally
  # (lib/steps/build/pack_and_build.ex), so Zig is required for native builds too.
  @erts_otp "29.0.3"
  @erts_cdn "https://beam-machine-universal.b-cdn.net/OTP-#{@erts_otp}"

  @burrito_all_targets [
    "aarch64-apple-darwin": [
      os: :darwin,
      cpu: :aarch64,
      custom_erts: "#{@erts_cdn}/macos/universal/otp_#{@erts_otp}_macos_universal.tar.gz"
    ],
    "x86_64-unknown-linux-gnu": [
      os: :linux,
      cpu: :x86_64,
      custom_erts: "#{@erts_cdn}/linux/x86_64/any/otp_#{@erts_otp}_linux_any_x86_64.tar.gz"
    ],
    "aarch64-unknown-linux-gnu": [
      os: :linux,
      cpu: :aarch64,
      custom_erts: "#{@erts_cdn}/linux/aarch64/any/otp_#{@erts_otp}_linux_any_aarch64.tar.gz"
    ]
  ]

  # Target KEYS must be Rust target triples, not friendly names: ex_tauri's
  # `rename_burrito_output/0` looks for `burrito_out/desktop_<rustc host triple>`
  # and renames it to `desktop-<triple>` for Tauri's `externalBin`. A key like
  # `macos_arm` builds fine but then fails the copy with
  # `could not copy from "burrito_out/desktop_aarch64-apple-darwin"`.
  #
  # Defaults to the HOST target only. `mix ex_tauri.build` builds every declared
  # target, and cross-compiling Linux from macOS fails at Zig's link step
  # (`compile exe desktop ReleaseSmall x86_64-linux 1 errors`) — so declaring all
  # three unconditionally makes the command fail on a Mac even though the native
  # build is fine. The spec's guidance is to build each platform on its own CI
  # runner rather than cross-compile, which this matches.
  #
  # Set `BURRITO_ALL_TARGETS=1` to opt into building every target, e.g. on a
  # runner where cross-compilation is known to work.
  defp burrito_targets do
    if System.get_env("BURRITO_ALL_TARGETS") == "1" do
      @burrito_all_targets
    else
      Keyword.take(@burrito_all_targets, [host_burrito_target()])
    end
  end

  defp host_burrito_target do
    arch = to_string(:erlang.system_info(:system_architecture))
    arm? = String.contains?(arch, "aarch64") or String.contains?(arch, "arm64")

    case {:os.type(), arm?} do
      {{:unix, :darwin}, _} -> :"aarch64-apple-darwin"
      {{:unix, :linux}, true} -> :"aarch64-unknown-linux-gnu"
      {{:unix, :linux}, false} -> :"x86_64-unknown-linux-gnu"
      other -> raise "no Burrito target defined for host #{inspect(other)} (#{arch})"
    end
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
      {:ex_tauri, "~> 0.2"},
      # Referenced directly as `&Burrito.wrap/1` in the :desktop release steps, so
      # declared explicitly rather than relied on transitively via :ex_tauri.
      {:burrito, "~> 1.6"}
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
      "ecto.setup": ["ecto.create", "ecto.migrate"],
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
      check: ["format --check-formatted", "compile --force --warnings-as-errors", "test --cover"]
    ]
  end
end
