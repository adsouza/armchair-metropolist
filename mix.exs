defmodule ArmchairMetropolist.MixProject do
  use Mix.Project

  def project do
    [
      app: :armchair_metropolist,
      version: "0.3.0",
      # 1.19.3, and the patch number is load-bearing. `config/runtime.exs` uses the
      # `E` regex modifier on its live-reload patterns — `:export`, which Elixir
      # added in **1.19.3** exactly (see `Regex` docs, "since Elixir 1.19.3"). A
      # `~> 1.19` claim would still admit 1.19.0-1.19.2 and fail there.
      #
      # This is the second time an untested floor drifted here: `Enum.sum_by/2`
      # (1.18+) once shipped under a `~> 1.17` claim, and `~r//E` then shipped under
      # a `~> 1.18` one. Both compiled locally because the dev machine was newer;
      # both were caught only by CI building the declared floor. That matrix entry
      # is why the claim stays honest — keep it pointed at this exact version.
      #
      # The lower bound from dependencies is unchanged and lower: `ex_tauri ->
      # igniter -> ex_ast` needs `~> 1.18`. The binding constraint is our own code.
      elixir: "~> 1.19 and >= 1.19.3",
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
          ArmchairMetropolist.PlayingGuide,
          # Developer tooling, not shipped code — a Mix task is not in either
          # release. Same rationale as the scaffolding above: counting it measures
          # how well the release procedure tests itself, not how well the
          # application is tested. Its three pure transforms *are* tested
          # (test/mix/tasks/version_set_test.exs); what is uncovered is `run/1`,
          # which writes real files and shells out to cargo, and whose whole point
          # is that the test suite must not do those things to its own checkout.
          # Left unignored it read 12%, taking the total from 94.86% to 91.46% —
          # still passing, but spending three points of headroom that belong to
          # the application.
          Mix.Tasks.Version.Set
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
          steps: [
            &assert_linux_erts_supported!/1,
            &build_assets/1,
            :assemble,
            &Burrito.wrap/1,
            &evict_burrito_payload_cache/1
          ],
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
    # The Linux targets deliberately do NOT set `custom_erts`, and must not.
    #
    # Burrito's musl step only runs for a target whose `erts_source` is
    # `{:precompiled, _}` (`deps/burrito/lib/steps/fetch/fetch_musl.ex:19`).
    # `custom_erts` makes it `{:url, _}` instead (`builder/target.ex:47`), so the
    # step falls through its bare `def execute(context), do: context` clause and
    # never writes `src/musl-runtime.so`. The wrapper then fails to compile:
    # `wrapper.zig:241` does `@embedFile("musl-runtime.so")` and its guard at :222
    # is a *runtime* check, so a comptime-Linux build analyses the embed
    # regardless. Setting `custom_erts` on a Linux target is an unconditional
    # wrapper-build failure, which is what reddened both desktop CI jobs.
    #
    # Dropping it costs nothing: the precompiled path builds the same CDN URL
    # these strings did, from the *host's* OTP. CI pins OTP to @erts_otp
    # (.github/workflows/ci.yml), and `assert_linux_erts_supported!/1` below makes
    # that agreement fail loudly instead of 404ing mid-build.
    #
    # darwin keeps its pin — macOS embeds no musl runtime, so the step is a no-op
    # there either way, and the pin is what stops this machine's OTP 29.0.4 (which
    # the CDN has not built) from 404ing.
    "x86_64-unknown-linux-gnu": [
      os: :linux,
      cpu: :x86_64
    ],
    "aarch64-unknown-linux-gnu": [
      os: :linux,
      cpu: :aarch64
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

  # A release STEP, not a check in `project/0`. `releases:` is evaluated on every
  # Mix invocation, so raising from there would abort `mix test` on any Linux host
  # whose OTP differs — including CI's own floor job, which runs a deliberately
  # older OTP. This only runs during `mix release desktop`.
  defp assert_linux_erts_supported!(release) do
    for {name, opts} <- burrito_targets(), opts[:os] == :linux, do: check_host_otp!(name)
    release
  end

  # Linux targets take their ERTS from the host's OTP version (see the note on
  # `@burrito_all_targets`), so that version must be one the CDN has actually
  # built. Without this, a mismatch surfaces as a 404 partway through a build, or
  # worse as a confusing Zig error — the failure mode that cost a day here once.
  # `@erts_otp` is the version probed and confirmed present on the CDN.
  defp check_host_otp!(target) do
    case host_otp_version() do
      # Cannot determine the host version — do not block a build over a missing
      # file. Burrito's own 404 remains the backstop.
      nil ->
        :ok

      @erts_otp ->
        :ok

      other ->
        Mix.raise("""
        Cannot build the Linux Burrito target #{target} on OTP #{other}.

        Linux targets fetch a precompiled ERTS for the host's OTP version, and
        only #{@erts_otp} is confirmed present on #{@erts_cdn |> String.replace("/OTP-#{@erts_otp}", "")}.

        Either build on OTP #{@erts_otp} (this is what CI pins), or re-probe the
        CDN for your version and update @erts_otp in mix.exs if it is available.

        Do not "fix" this by adding `custom_erts:` back to a Linux target — that
        silently disables Burrito's musl fetch and breaks the wrapper build.
        """)
    end
  end

  # OTP's full version (e.g. "29.0.3"); `System.otp_release/0` gives only "29".
  defp host_otp_version do
    [to_string(:code.root_dir()), "releases", System.otp_release(), "OTP_VERSION"]
    |> Path.join()
    |> File.read()
    |> case do
      {:ok, contents} -> String.trim(contents)
      {:error, _} -> nil
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

  # Every place this project stores its own version, checked as one number.
  #
  # They drift silently because each feeds a different consumer and no build step
  # consults more than one: `mix.exs` names Burrito's payload cache directory,
  # `tauri.conf.json` names the .deb and its control `Version:` field, `Cargo.toml` is
  # the fallback Tauri takes when `tauri.conf.json` omits `version`
  # (crates/tauri-cli/src/interface/rust.rs:1093), `Cargo.lock` is what `cargo audit`
  # reads, and the Flatpak's AppStream metainfo is what a software centre shows the
  # user. This found a real drift the day it was written: the two Cargo files said
  # 0.2.0 while the two that actually ship said 0.1.0.
  #
  # A step in `mix check` rather than a git hook, deliberately. `.githooks/pre-push` is
  # a wrapper around `mix check` and nothing else, so this is picked up by that hook AND
  # by CI, which runs the same alias. A hook-only check would be a gate no runner sees.
  #
  # Only the *product's* version belongs here. The tool versions in `config/config.exs`
  # (Tauri CLI, tailwind, daisyui) and in the workflow (Elixir, OTP, Zig) are unrelated
  # numbers, and a check that cries wolf gets bypassed as a reflex.
  defp check_versions(_args) do
    sites = version_sites()

    # Before comparing: a site that could not be read is nil, and four nils compare
    # equal. Without this clause a renamed file or an extractor whose pattern stopped
    # matching would make this check pass while reading nothing at all.
    case Enum.filter(sites, fn {_file, version} -> is_nil(version) end) do
      [] ->
        :ok

      unreadable ->
        Mix.raise("""
        Could not read a version from #{Enum.map_join(unreadable, ", ", &elem(&1, 0))}.

        Either the file is missing, or its format changed and the extractor in mix.exs
        needs updating. This is deliberately fatal: a version check that silently reads
        nothing passes forever.
        """)
    end

    case sites |> Enum.map(&elem(&1, 1)) |> Enum.uniq() do
      [agreed] ->
        Mix.shell().info("[versions] #{agreed}")

      _ ->
        Mix.raise("""
        Version declarations disagree.

        #{Enum.map_join(sites, "\n", fn {f, v} -> "  #{String.pad_trailing(f, 28)} #{v}" end)}

        Every site above must carry the same value. Rather than editing them by
        hand, move them all together:

            mix version.set X.Y.Z
        """)
    end
  end

  # OTP's own JSON decoder rather than Jason: this runs as the *first* step of the
  # `check` alias, before any task has put the dependencies' beam files on the code
  # path. `:json` is stdlib from OTP 27, which is this project's floor.
  @doc false
  # Public so `mix version.set` can re-derive this list after writing, instead of
  # keeping a second copy of these readers. A hand-maintained mirror of a list the
  # code already owns is precisely the thing that drifts, and the drift is silent.
  # `ArmchairMetropolist.MixProject` is loaded for the whole of any Mix invocation,
  # so the task can call this with no compile-order problem.
  @metainfo_path "packaging/flatpak/io.github.adsouza.armchair-metropolist.metainfo.xml"

  def version_sites do
    [
      {"mix.exs", mix_exs_version()},
      {"src-tauri/tauri.conf.json", tauri_conf_version()},
      {"src-tauri/Cargo.toml", cargo_toml_version()},
      {"src-tauri/Cargo.lock", cargo_lock_version()},
      {@metainfo_path, metainfo_version()}
    ] ++ release_tag_site()
  end

  # The Flatpak's AppStream metadata, which arrived after this check did and was not
  # added to it — so the first bump after the Flatpak landed would have shipped a
  # 0.2.0 package advertising 0.1.0 to every software centre, with all four other
  # sites agreeing and `mix check` green. Exactly the failure this list exists for,
  # reintroduced by adding a file rather than by editing one.
  #
  # Reads the FIRST <release>, because AppStream orders that list newest-first and
  # `mix version.set` maintains that by prepending. The rest of the list is release
  # history and must not be touched.
  defp metainfo_version do
    with {:ok, body} <- File.read(@metainfo_path),
         [_, version] <- Regex.run(~r/<release\s+version="([^"]+)"/, body) do
      version
    else
      _ -> nil
    end
  end

  # From disk, not from Mix.Project.config()[:version], which is cached at load
  # time. `mix version.set` rewrites this file and re-runs the comparison in the
  # same process; against the cached value it would be grading its own homework
  # with the answer sheet from before the edit.
  defp mix_exs_version do
    with {:ok, body} <- File.read("mix.exs"),
         [_, version] <- Regex.run(~r/^\s*version:\s*"([^"]+)"/m, body) do
      version
    else
      _ -> nil
    end
  end

  # The git tag, and only when a release workflow put one in the environment.
  #
  #   unset or ""   -> []             four sites: exactly today's behaviour.
  #   "v1.2.3"      -> [{_, "1.2.3"}] compared with the rest; disagreement fatal.
  #   anything else -> [{_, nil}]     trips the nil-guard in check_versions/1.
  #
  # Returning [] for a *malformed* tag would skip the check in silence — the exact
  # "a version check that silently reads nothing passes forever" failure the
  # nil-guard exists to prevent.
  #
  # "" is the deliberate exception and is not a nicety. GitHub Actions cannot
  # conditionally omit an environment variable, so a job-level
  # `RELEASE_TAG: ${{ github.ref_type == 'tag' && github.ref_name || '' }}`
  # evaluates to "" on every branch push. Treating "" as malformed would make this
  # guard fatal on every push to main and every pull request — including the
  # pre-push hook — and it would be ripped out within a day. "" means absent. The
  # shapes a *human* gets wrong ("v0.2", a full "refs/tags/..." ref) all still
  # trip it.
  defp release_tag_site do
    case System.get_env("RELEASE_TAG") do
      nil -> []
      "" -> []
      tag -> [{"git tag #{tag}", tag_version(tag)}]
    end
  end

  # \A and \z rather than ^ and $: $ accepts a trailing newline, and a workflow
  # handing over "refs/tags/v1.2.3\n" is exactly the input this must reject.
  defp tag_version("v" <> rest) do
    if Regex.match?(~r/\A\d+\.\d+\.\d+\z/, rest), do: rest, else: nil
  end

  defp tag_version(_other), do: nil

  defp tauri_conf_version do
    with {:ok, body} <- File.read("src-tauri/tauri.conf.json"),
         {:ok, %{"version" => version}} <- decode_json(body) do
      version
    else
      _ -> nil
    end
  end

  defp decode_json(body) do
    {:ok, :json.decode(body)}
  rescue
    _ -> :error
  end

  # A regex rather than a TOML dependency, to read one field from two cargo-generated
  # files whose formatting is stable. Anchored to the `[package]` table and stopped at
  # the next table header, so a dependency's own `version = ` cannot match. Returns nil
  # rather than a wrong answer if the shape ever changes, and nil is fatal above.
  defp cargo_toml_version do
    with {:ok, body} <- File.read("src-tauri/Cargo.toml"),
         [_, package_table] <- Regex.run(~r/^\[package\]\n(.*?)(?=^\[|\z)/ms, body),
         [_, version] <- Regex.run(~r/^version\s*=\s*"([^"]+)"/m, package_table) do
      version
    else
      _ -> nil
    end
  end

  defp cargo_lock_version do
    app = Mix.Project.config()[:app]

    with {:ok, body} <- File.read("src-tauri/Cargo.lock"),
         [_, version] <- Regex.run(~r/name = "#{app}"\nversion = "([^"]+)"/, body) do
      version
    else
      _ -> nil
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
        # First because it is milliseconds, and the same argument this alias already
        # makes for putting the security checks ahead of the suite applies with more
        # force to something this cheap.
        &check_versions/1,
        "format --check-formatted",
        "compile --force --warnings-as-errors",
        "sobelow",
        "deps.audit",
        "test --cover"
      ]
    ]
  end
end
