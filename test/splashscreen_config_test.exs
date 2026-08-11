defmodule ArmchairMetropolist.SplashscreenConfigTest do
  use ExUnit.Case, async: true

  @tauri_config Path.expand("../src-tauri/tauri.conf.json", __DIR__)
  @splashscreen Path.expand("../src-tauri/splashscreen.html", __DIR__)

  test "the main window starts hidden until its real page has loaded" do
    tauri_config = @tauri_config |> File.read!() |> Jason.decode!()
    main_window = get_in(tauri_config, ["app", "windows", Access.at(0)])

    assert tauri_config["app"]["macOSPrivateApi"] == true
    assert main_window["label"] == "main"
    assert main_window["visible"] == false
  end

  test "the local splashscreen has accessible loading content" do
    splashscreen = File.read!(@splashscreen)

    assert splashscreen =~ "Armchair Metropolist"
    assert splashscreen =~ "Acquiring construction permits..."
    assert splashscreen =~ ~s(role="status")
    assert splashscreen =~ "prefers-reduced-motion"
    assert splashscreen =~ "background: transparent"
  end
end
