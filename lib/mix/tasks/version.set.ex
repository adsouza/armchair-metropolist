defmodule Mix.Tasks.Version.Set do
  @shortdoc "Moves every version declaration to X.Y.Z"

  @moduledoc """
  Sets the project version across all four places that declare it.

      mix version.set 0.2.0

  Four files must agree or `mix check` refuses to build, and one of them is a
  lock file that must be *regenerated* rather than edited. The incantation for
  that is not the obvious one: `cargo metadata --offline` exits 101, and the
  form that works is `cargo update --offline -p armchair_metropolist`.

  `check_versions/1` in `mix.exs` already *catches* drift between these files.
  This task *prevents* it, and then re-runs that same comparison rather than
  trusting its own writes.

  Bumping the version is not bookkeeping. A production Burrito binary unpacks
  its payload exactly once, keyed on `<name>_erts-<erts>_<app version>`, so two
  packages sharing a version means the second installs code that never runs.
  """

  use Mix.Task

  # This repository compiles with the `boundary` checker and `{:mix, :runtime}`
  # is a checked application, so a module under lib/ must be classified. A Mix
  # task belongs to no layer of the application — it is tooling — which is what
  # `top_level?: true` is for, the same way `ArmchairMetropolist.Release` does it.
  use Boundary, top_level?: true, deps: [Mix]

  @version_pattern ~r/\A\d+\.\d+\.\d+\z/

  @impl Mix.Task
  def run([version]) do
    unless Regex.match?(@version_pattern, version) do
      Mix.raise("""
      Not a version: #{inspect(version)}

      Expected MAJOR.MINOR.PATCH, digits only — for example 0.2.0. The git tag
      that releases it will be this value prefixed with "v".
      """)
    end

    update!("mix.exs", &bump_mix_exs(&1, version))
    update!("src-tauri/tauri.conf.json", &bump_tauri_conf(&1, version))
    update!("src-tauri/Cargo.toml", &bump_cargo_toml(&1, version))
    regenerate_lock!()
    verify!()
  end

  def run(_args) do
    Mix.raise("Usage: mix version.set X.Y.Z")
  end

  @doc "Rewrites the `version:` entry in a mix.exs body."
  @spec bump_mix_exs(binary(), binary()) :: binary()
  def bump_mix_exs(body, version) do
    String.replace(body, ~r/^(\s*version:\s*)"[^"]+"/m, ~s|\\1"#{version}"|, global: false)
  end

  @doc ~S"""
  Rewrites the top-level `"version"` entry in a tauri.conf.json body.
  """
  @spec bump_tauri_conf(binary(), binary()) :: binary()
  def bump_tauri_conf(body, version) do
    String.replace(body, ~r/^(\s*"version":\s*)"[^"]+"/m, ~s|\\1"#{version}"|, global: false)
  end

  @doc "Rewrites the `version` entry of Cargo.toml's `[package]` table."
  @spec bump_cargo_toml(binary(), binary()) :: binary()
  def bump_cargo_toml(body, version) do
    String.replace(body, ~r/^(version\s*=\s*)"[^"]+"/m, ~s|\\1"#{version}"|, global: false)
  end

  # Raising when nothing changed is the point: a silent no-op here would leave
  # one site behind and the disagreement would surface as a confusing CI failure
  # rather than as "this file's pattern stopped matching".
  defp update!(path, fun) do
    body = File.read!(path)
    new_body = fun.(body)

    if new_body == body do
      Mix.raise("#{path} was not changed — its version pattern did not match.")
    end

    File.write!(path, new_body)
    Mix.shell().info("  updated #{path}")
  end

  # `cargo update`, not a hand edit: the lock records a checksum-bearing graph and
  # editing it by hand desynchronises it from Cargo.toml in ways cargo only
  # complains about later. `--offline` because this must work without network and
  # the package is local.
  defp regenerate_lock! do
    case System.cmd("cargo", ["update", "--offline", "-p", "armchair_metropolist"],
           cd: "src-tauri",
           stderr_to_stdout: true
         ) do
      {_out, 0} -> Mix.shell().info("  updated src-tauri/Cargo.lock")
      {out, status} -> Mix.raise("cargo update failed (#{status}):\n\n#{out}")
    end
  end

  # Re-derive rather than assume. This calls the same reader that guards the
  # build, so a write that looked fine but landed in the wrong place is caught
  # here rather than by CI. `version_sites/0` reads mix.exs from disk precisely
  # so that this sees the edit made moments ago.
  defp verify! do
    sites = ArmchairMetropolist.MixProject.version_sites()

    case sites |> Enum.map(&elem(&1, 1)) |> Enum.uniq() do
      [agreed] when is_binary(agreed) ->
        Mix.shell().info("\nAll #{length(sites)} sites now declare #{agreed}.")

      _ ->
        Mix.raise("""
        Wrote the files but they still disagree:

        #{Enum.map_join(sites, "\n", fn {f, v} -> "  #{String.pad_trailing(f, 28)} #{inspect(v)}" end)}
        """)
    end
  end
end
