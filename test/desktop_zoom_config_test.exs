defmodule ArmchairMetropolist.DesktopZoomConfigTest do
  use ExUnit.Case, async: true

  @tauri_config Path.expand("../src-tauri/tauri.conf.json", __DIR__)
  test "app-owned desktop zoom can detect Tauri without a competing hotkey handler" do
    tauri_config = @tauri_config |> File.read!() |> Jason.decode!()

    assert get_in(tauri_config, ["app", "withGlobalTauri"])
    refute get_in(tauri_config, ["app", "windows", Access.at(0), "zoomHotkeysEnabled"])
  end
end
