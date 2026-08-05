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

  describe "bump_metainfo/3" do
    @releases ~s|  <releases>\n    <release version="0.1.0" date="2026-08-04" />\n  </releases>|

    test "prepends the new release above the existing one" do
      after_ = Set.bump_metainfo(@releases, "0.2.0", "2026-08-05")

      assert after_ ==
               ~s|  <releases>\n| <>
                 ~s|    <release version="0.2.0" date="2026-08-05" />\n| <>
                 ~s|    <release version="0.1.0" date="2026-08-04" />\n| <>
                 ~s|  </releases>|
    end

    # The point of prepending rather than rewriting: <releases> is the changelog a
    # software centre displays, so overwriting the head silently deletes history.
    test "keeps every earlier release" do
      two =
        ~s|  <releases>\n| <>
          ~s|    <release version="0.2.0" date="2026-08-05" />\n| <>
          ~s|    <release version="0.1.0" date="2026-08-04" />\n| <>
          ~s|  </releases>|

      after_ = Set.bump_metainfo(two, "0.3.0", "2026-09-01")

      assert after_ =~ ~s|<release version="0.3.0" date="2026-09-01" />|
      assert after_ =~ ~s|<release version="0.2.0" date="2026-08-05" />|
      assert after_ =~ ~s|<release version="0.1.0" date="2026-08-04" />|
    end

    # Re-running the task must not stack duplicates: the head is updated in place.
    test "updates the date instead of duplicating the head" do
      after_ = Set.bump_metainfo(@releases, "0.1.0", "2026-08-06")

      assert after_ =~ ~s|<release version="0.1.0" date="2026-08-06" />|
      refute after_ =~ ~s|date="2026-08-04"|
      assert after_ |> String.split("<release ") |> length() == 2
    end

    # mix.exs reads the FIRST <release> as the current version, so the new entry
    # must land above the old one. Asserting on order, not just presence — a
    # version appended to the bottom would satisfy every =~ above and still make
    # the reader report the previous release.
    test "the new version is the one mix.exs would read" do
      after_ = Set.bump_metainfo(@releases, "0.2.0", "2026-08-05")

      assert [_, first] = Regex.run(~r/<release\s+version="([^"]+)"/, after_)
      assert first == "0.2.0"
    end

    # The head entry gains a <description> the moment anyone writes release notes,
    # which makes it a container rather than self-closing. A pattern anchored on
    # `/>` skips it, matches the release *below*, and inserts the new version under
    # the old one — leaving mix.exs reading a superseded version from the top of the
    # list. Assert the ordering, since presence alone would pass either way.
    test "still prepends when the head entry has a description" do
      container =
        ~s|  <releases>\n| <>
          ~s|    <release version="0.2.0" date="2026-08-05">\n| <>
          ~s|      <description><p>First packaged release.</p></description>\n| <>
          ~s|    </release>\n| <>
          ~s|    <release version="0.1.0" date="2026-08-04" />\n| <>
          ~s|  </releases>|

      after_ = Set.bump_metainfo(container, "0.3.0", "2026-09-01")

      assert [_, first] = Regex.run(~r/<release\s+version="([^"]+)"/, after_)
      assert first == "0.3.0"
      assert after_ =~ ~s|<description><p>First packaged release.</p></description>|
      assert after_ =~ ~s|<release version="0.2.0" date="2026-08-05">|
    end

    # Idempotent re-run against a container head must not strip its description or
    # turn the tag into a self-closing one, which would orphan </release>.
    test "updates a container head in place, keeping its form and children" do
      container =
        ~s|    <release version="0.2.0" date="2026-08-05">\n| <>
          ~s|      <description><p>Notes.</p></description>\n| <>
          ~s|    </release>|

      after_ = Set.bump_metainfo(container, "0.2.0", "2026-08-07")

      assert after_ =~ ~s|<release version="0.2.0" date="2026-08-07">|
      refute after_ =~ ~s|date="2026-08-05"|
      refute after_ =~ ~s|/>|
      assert after_ =~ ~s|</release>|
      assert after_ =~ ~s|<description><p>Notes.</p></description>|
    end

    test "leaves the rest of the document alone" do
      body =
        ~s|<component type="desktop-application">\n| <>
          ~s|  <id>io.github.adsouza.armchair-metropolist</id>\n| <>
          ~s|  <project_license>AGPL-3.0-only</project_license>\n| <>
          @releases <> ~s|\n</component>|

      after_ = Set.bump_metainfo(body, "0.2.0", "2026-08-05")

      assert after_ =~ ~s|<project_license>AGPL-3.0-only</project_license>|
      assert after_ =~ ~s|<id>io.github.adsouza.armchair-metropolist</id>|
    end
  end
end
