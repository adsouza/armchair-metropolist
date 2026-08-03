defmodule ArmchairMetropolist.Infrastructure.Desktop.ConfigTest do
  @moduledoc """
  These overrides used to live in `config/runtime.exs`, where no test could
  reach them. They are asserted here precisely because nothing else in the
  system would notice if they stopped being applied: a wrong `:ip` still serves
  requests, and a missing `check_origin` fails only in a packaged window.

  `async: false`: mutates application env and OS env.
  """
  use ExUnit.Case, async: false

  alias ArmchairMetropolist.Infrastructure.Desktop.Config, as: DesktopConfig
  alias ArmchairMetropolist.Infrastructure.Persistence.FileSnapshotStore
  alias ArmchairMetropolist.Infrastructure.Desktop.TauriNotifier

  @endpoint_key ArmchairMetropolistWeb.Endpoint
  @app_keys [
    :start_repo,
    :start_shutdown_manager,
    :snapshot_repository,
    :notifier,
    :snapshot_dir
  ]

  setup do
    saved =
      Map.new([@endpoint_key | @app_keys], &{&1, Application.get_env(:armchair_metropolist, &1)})

    saved_env = Map.new(~w(ARMCHAIR_DESKTOP PORT SECRET_KEY_BASE), &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:armchair_metropolist, key)
        {key, value} -> Application.put_env(:armchair_metropolist, key, value)
      end)

      Enum.each(saved_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  describe "desktop?/0" do
    test "recognises the marker the Tauri host injects" do
      for value <- ~w(1 true) do
        System.put_env("ARMCHAIR_DESKTOP", value)
        assert DesktopConfig.desktop?(), "#{inspect(value)} should mark the desktop target"
      end
    end

    test "is false for anything else, so mix and the server release are unaffected" do
      System.delete_env("ARMCHAIR_DESKTOP")
      refute DesktopConfig.desktop?()

      for value <- ~w(0 false no "") do
        System.put_env("ARMCHAIR_DESKTOP", value)
        refute DesktopConfig.desktop?(), "#{inspect(value)} must not mark the desktop target"
      end
    end
  end

  describe "apply!/0 outside the desktop target" do
    test "changes nothing at all" do
      System.delete_env("ARMCHAIR_DESKTOP")

      before =
        Map.new(
          [@endpoint_key | @app_keys],
          &{&1, Application.get_env(:armchair_metropolist, &1)}
        )

      assert :ok = DesktopConfig.apply!()

      after_ =
        Map.new(
          [@endpoint_key | @app_keys],
          &{&1, Application.get_env(:armchair_metropolist, &1)}
        )

      assert before == after_, "a non-desktop boot must keep the server configuration"
    end
  end

  describe "apply!/0 on the desktop target" do
    setup do
      System.put_env("ARMCHAIR_DESKTOP", "1")
      System.put_env("PORT", "4321")
      System.put_env("SECRET_KEY_BASE", String.duplicate("k", 64))
      :ok
    end

    test "selects the file adapter and the native notifier, and starts no Repo" do
      assert :ok = DesktopConfig.apply!()

      assert Application.get_env(:armchair_metropolist, :start_repo) == false
      assert Application.get_env(:armchair_metropolist, :start_shutdown_manager) == true
      assert Application.get_env(:armchair_metropolist, :snapshot_repository) == FileSnapshotStore
      assert Application.get_env(:armchair_metropolist, :notifier) == TauriNotifier
      assert is_binary(Application.get_env(:armchair_metropolist, :snapshot_dir))
    end

    test "binds loopback only and disables origin checking" do
      assert :ok = DesktopConfig.apply!()

      endpoint = Application.get_env(:armchair_metropolist, @endpoint_key)

      assert Keyword.fetch!(endpoint, :check_origin) == false,
             "an ephemeral per-launch port cannot be allowlisted, so this must be off"

      assert endpoint |> Keyword.fetch!(:http) |> Keyword.fetch!(:ip) == {127, 0, 0, 1},
             "loopback only is what makes check_origin: false a safe trade"

      assert endpoint |> Keyword.fetch!(:http) |> Keyword.fetch!(:port) == 4321
      assert Keyword.fetch!(endpoint, :url) == [host: "127.0.0.1", port: 4321, scheme: "http"]
      assert Keyword.fetch!(endpoint, :server) == true
    end

    test "bounds the connection drain so terminate/2 can still write a snapshot" do
      assert :ok = DesktopConfig.apply!()

      assert Application.get_env(:armchair_metropolist, @endpoint_key)
             |> Keyword.fetch!(:http)
             |> Keyword.fetch!(:thousand_island_options) == [shutdown_timeout: 100]
    end

    test "preserves unrelated endpoint settings rather than replacing the keyword list" do
      Application.put_env(:armchair_metropolist, @endpoint_key,
        render_errors: [formats: [html: SomeErrorHTML]],
        http: [compress: true]
      )

      assert :ok = DesktopConfig.apply!()

      endpoint = Application.get_env(:armchair_metropolist, @endpoint_key)
      assert Keyword.fetch!(endpoint, :render_errors) == [formats: [html: SomeErrorHTML]]
      assert endpoint |> Keyword.fetch!(:http) |> Keyword.fetch!(:compress) == true
    end

    test "is idempotent" do
      assert :ok = DesktopConfig.apply!()
      first = Application.get_env(:armchair_metropolist, @endpoint_key)

      assert :ok = DesktopConfig.apply!()
      assert Application.get_env(:armchair_metropolist, @endpoint_key) == first
    end

    test "fails loudly when the host did not supply PORT" do
      System.delete_env("PORT")

      assert_raise RuntimeError, ~r/expects PORT/, fn -> DesktopConfig.apply!() end
    end

    test "fails loudly when the host did not supply SECRET_KEY_BASE" do
      System.delete_env("SECRET_KEY_BASE")

      assert_raise RuntimeError, ~r/expects SECRET_KEY_BASE/, fn -> DesktopConfig.apply!() end
    end
  end
end
