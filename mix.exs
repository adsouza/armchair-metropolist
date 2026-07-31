defmodule ArmchairMetropolist.MixProject do
  use Mix.Project

  def project do
    [
      app: :armchair_metropolist,
      version: "0.1.0",
      # 1.18, not the 1.17 this used to claim: `ex_tauri -> igniter -> ex_ast`
      # requires `~> 1.18`, so a 1.17 build cannot resolve. An untested floor
      # drifts — `Enum.sum_by/2` (1.18+) once shipped here under a 1.17 claim and
      # only passed because the dev machine was newer. CI now builds this exact
      # version as well as the current one, so the claim stays honest.
      elixir: "~> 1.18",
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
          ArmchairMetropolist.SnapshotRepositoryOrderingContract,
          ArmchairMetropolist.PlayingGuide
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
      #
      # `&evict_burrito_payload_cache/1` runs last and is load-bearing — see its
      # own comment. Without it a rebuilt binary silently keeps running the code
      # from the first build you ever made.
      #
      # Two releases exist, so `default_release` must say which a bare
      # `mix release` means — Gigalixir's releases buildpack runs exactly that, and
      # Mix refuses to choose between two. Without it the deploy fails with
      # "you must specify the name of the release", and the desktop release is the
      # one you least want a server build to pick: it wraps the whole thing in a
      # Burrito binary and needs Zig on the builder.
      default_release: :armchair_metropolist,
      releases: [
        # The server target, deployed to Gigalixir. Named for the OTP application
        # because Gigalixir's releases buildpack starts `/app/bin/<app name>`.
        armchair_metropolist: [
          steps: [&deploy_assets/1, :assemble]
        ],
        desktop: [
          steps: [&build_assets/1, :assemble, &Burrito.wrap/1, &evict_burrito_payload_cache/1],
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
  # Points git at the hooks in .githooks/. `.git/hooks` is not versioned, so without
  # this a fresh clone has no hooks at all and the gate goes back to being something
  # you have to remember — which is exactly how every commit in this repository's
  # early history was made.
  #
  # Idempotent, and safe to run outside a checkout (a release tarball, a vendored
  # copy): it reports and moves on rather than failing the whole `mix setup`.
  defp install_git_hooks(_args) do
    if File.exists?(".git") do
      case System.cmd("git", ["config", "core.hooksPath", ".githooks"], stderr_to_stdout: true) do
        {_out, 0} ->
          # Belt and braces. Git does version the executable bit, so a clone should
          # already have it, but a hook that is not executable is silently ignored —
          # the worst possible failure for something whose whole job is to object.
          Enum.each(Path.wildcard(".githooks/*"), &File.chmod!(&1, 0o755))
          Mix.shell().info("[git hooks] core.hooksPath -> .githooks")

        {out, code} ->
          Mix.shell().error("[git hooks] git config failed (#{code}): #{String.trim(out)}")
      end
    else
      Mix.shell().info("[git hooks] not a git checkout, skipping")
    end
  end

  defp build_assets(%Mix.Release{} = release) do
    Mix.Task.run("assets.build")
    release
  end

  # `assets.deploy`, not `assets.build`: this target's CSS and JS cross the public
  # internet to real browsers, so minifying earns its keep, and `phx.digest`'s
  # content-hashed filenames are what let the cache headers be aggressive. Both are
  # pointless for the desktop window, which reads them off a loopback socket — see
  # `build_assets/1`.
  #
  # `config/runtime.exs` sets `cache_static_manifest` for this target only, so the
  # manifest this produces is actually consulted.
  defp deploy_assets(%Mix.Release{} = release) do
    Mix.Task.run("assets.deploy")
    release
  end

  # Deletes the unpacked payload a previous build left on this machine, so the
  # binary we just wrote actually gets extracted the next time it runs.
  #
  # A Burrito binary carries a compressed release and unpacks it to
  # `<app data>/.burrito/<name>_erts-<erts>_<app version>` on first launch. In a
  # production build it then unpacks *never again*: `wrapper.zig` decides with
  # nothing more than "does `_metadata.json` exist in that directory", and
  # `wants_clean_install` is hardwired to `!IS_PROD`. The directory name is the
  # only cache key, and it holds neither a payload hash nor a build timestamp —
  # despite the comment above `get_install_dir` claiming it "combine[s] the hash
  # of the payload".
  #
  # So while `version` in this file stays put, every rebuild is a no-op at
  # runtime. This cost a long debugging session: the packaged app kept binding
  # 0.0.0.0 and rejecting its own LiveView socket on origin, and each new fix
  # changed nothing, because the sidecar was still executing the *first* build
  # ever made — one that predated the module doing the configuring. Nothing
  # anywhere reports this; the launcher logs "Skipping archive unpacking" only at
  # debug level, which the Tauri host does not show.
  #
  # Globbed on the ERTS version because that number is Burrito's, not ours: the
  # pinned OTP 29.0.3 reports ERTS 17.0.4, and maintaining that mapping here
  # would just be one more thing to keep in sync.
  defp evict_burrito_payload_cache(%Mix.Release{} = release) do
    case burrito_install_base() do
      nil ->
        Mix.shell().info("[burrito] unknown app-data dir; clear the payload cache by hand")

      base ->
        Path.wildcard(Path.join(base, "#{release.name}_erts-*_#{release.version}"))
        |> Enum.each(fn dir ->
          File.rm_rf!(dir)
          Mix.shell().info("[burrito] evicted stale payload #{dir}")
        end)
    end

    release
  end

  # Mirrors `get_app_data_dir/2` in Burrito's `wrapper.zig`. Only the host's own
  # cache can be evicted, which is the case that matters: a cross-built binary
  # lands on a machine that has never unpacked it.
  defp burrito_install_base do
    case {:os.type(), System.get_env("XDG_DATA_HOME"), System.user_home()} do
      {_, _, nil} ->
        nil

      {{:unix, :darwin}, _, home} ->
        Path.join([home, "Library", "Application Support", ".burrito"])

      {{:unix, _}, nil, home} ->
        Path.join([home, ".local", "share", ".burrito"])

      {{:unix, _}, xdg, _} ->
        Path.join(xdg, ".burrito")

      _ ->
        nil
    end
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {ArmchairMetropolist.Application, []},
      # :inets is required by the desktop target — Burrito's release wrapper and
      # ExTauri's updater both reach for :httpc at runtime.
      #
      # :ssl is required by the *server* target: the production Repo connects over
      # TLS, and postgrex calls into the :ssl application at runtime without
      # declaring it, so a release that omits it fails to connect rather than
      # failing to build.
      extra_applications: [:logger, :runtime_tools, :inets, :ssl]
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
      # Phoenix-specific security scanner, run as part of `mix check`. Matters more
      # now that the server target is publicly deployed with a database behind it.
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      # Checks mix.lock against published Elixir advisories. Complements Sobelow
      # rather than overlapping it: Sobelow reads this project's source, mix_audit
      # reads the dependency tree.
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
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
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build", &install_git_hooks/1],
      # For an existing clone that predates the hooks, or after someone has pointed
      # core.hooksPath somewhere else.
      githooks: [&install_git_hooks/1],
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
      # (catches boundary violations too, since :boundary is in `compilers`),
      # Sobelow's security scan, then the full test suite under coverage
      # instrumentation, which enforces `test_coverage[:threshold]` above.
      # `@tag :cold_vm` runs by default (no `--exclude`) - it is a ~0.7s regression
      # test for a real data-loss bug (see file_snapshot_store_test.exs), fast
      # enough that excluding it from the gate would buy nothing.
      #
      # The two security checks go before the suite: together they take a couple of
      # seconds, and a finding is worth surfacing before a minute of tests.
      # `sobelow` reads this project's source; its settings live in .sobelow-conf so
      # a laptop run and CI agree, and note the `exit` value there is load-bearing
      # and easy to get silently wrong. `deps.audit` reads mix.lock against published
      # advisories and exits 1 on any hit, with no threshold to misconfigure.
      #
      # `deps.audit` can turn a green build red with no change to this repository, on
      # the day an advisory lands for something in mix.lock. That is the point of it.
      # It needs no manual refresh: it git-clones mirego/elixir-security-advisories
      # to ~/.local/share and pulls it on every run — so this gate wants `git` and
      # network. Offline it degrades rather than fails, ignoring git's exit status and
      # scanning against whatever clone is on disk.
      check: [
        "format --check-formatted",
        "compile --force --warnings-as-errors",
        "sobelow",
        "deps.audit",
        "test --cover"
      ]
    ]
  end
end
