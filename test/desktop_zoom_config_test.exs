defmodule ArmchairMetropolist.DesktopZoomConfigTest do
  use ExUnit.Case, async: true

  @tauri_config Path.expand("../src-tauri/tauri.conf.json", __DIR__)
  @zoom_hook Path.expand("../assets/js/desktop_zoom.js", __DIR__)

  test "app-owned desktop zoom can detect Tauri without a competing hotkey handler" do
    tauri_config = @tauri_config |> File.read!() |> Jason.decode!()

    assert get_in(tauri_config, ["app", "withGlobalTauri"])
    refute get_in(tauri_config, ["app", "windows", Access.at(0), "zoomHotkeysEnabled"])
  end

  test "desktop zoom is restored from persistent webview storage" do
    hook = File.read!(@zoom_hook)

    assert hook =~ ~s(const STORAGE_KEY = "armchair-metropolist:desktop-zoom")
    assert hook =~ "window.localStorage.getItem(STORAGE_KEY)"
    assert hook =~ "window.localStorage.setItem(STORAGE_KEY, String(zoom))"
    assert hook =~ "this.zoomIndex = restoredZoomIndex()"
    assert hook =~ "this.applyZoom()"
  end
end
