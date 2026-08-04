defmodule Mix.Tasks.Version.SetTest do
  @moduledoc """
  The transforms are pure so these tests never touch the real `mix.exs` — a test
  that rewrote the project's own version would corrupt the tree it runs in.

  Each "leaves … alone" case is the one that earns its keep. All three of these
  files contain several version-shaped strings, and the failure a careless
  pattern actually produces is not "nothing changed", it is "the wrong line
  changed" — which still looks like success to the caller and only surfaces when
  cargo or Mix rejects the file much later.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Version.Set

  describe "bump_mix_exs/2" do
    test "rewrites the project version" do
      before =
        ~s|  def project do\n    [\n      app: :armchair_metropolist,\n      version: "0.1.0",\n      elixir: "~> 1.19"\n    ]\n  end|

      assert Set.bump_mix_exs(before, "0.2.0") =~ ~s|version: "0.2.0"|
    end

    test "leaves the elixir requirement alone" do
      before = ~s|      version: "0.1.0",\n      elixir: "~> 1.19 and >= 1.19.3"|
      after_ = Set.bump_mix_exs(before, "0.2.0")

      assert after_ =~ ~s|elixir: "~> 1.19 and >= 1.19.3"|
      refute after_ =~ ~s|version: "0.1.0"|
    end
  end

  describe "bump_tauri_conf/2" do
    test "rewrites the top-level version" do
      before =
        ~s|{\n  "productName": "Armchair Metropolist",\n  "version": "0.1.0",\n  "identifier": "com.example.app"\n}|

      assert Set.bump_tauri_conf(before, "0.2.0") =~ ~s|"version": "0.2.0"|
    end

    test "leaves the declared dependency versions alone" do
      before =
        ~s|{\n  "version": "0.1.0",\n  "bundle": { "linux": { "deb": { "depends": ["libc6 (>= 2.39)"] } } }\n}|

      after_ = Set.bump_tauri_conf(before, "0.2.0")

      assert after_ =~ ~s|"version": "0.2.0"|
      assert after_ =~ ~s|libc6 (>= 2.39)|
    end
  end

  describe "bump_cargo_toml/2" do
    test "rewrites the [package] version" do
      before =
        ~s|[package]\nname = "armchair_metropolist"\nversion = "0.1.0"\n\n[dependencies]\ntauri = { version = "2.0" }|

      assert Set.bump_cargo_toml(before, "0.2.0") =~ ~s|version = "0.2.0"|
    end

    test "leaves a dependency version alone" do
      before = ~s|[package]\nversion = "0.1.0"\n\n[dependencies]\ntauri = { version = "2.0" }|
      after_ = Set.bump_cargo_toml(before, "0.2.0")

      assert after_ =~ ~s|tauri = { version = "2.0" }|
      refute after_ =~ ~s|version = "0.1.0"|
    end
  end
end
