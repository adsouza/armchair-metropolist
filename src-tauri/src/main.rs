// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::webview::{Color, PageLoadEvent};
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_shell::process::CommandEvent;
use tauri_plugin_shell::ShellExt;
use tauri_plugin_window_state::{AppHandleExt, StateFlags};

use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::Mutex;
use std::time::Duration;

// Flipped to false when the app is quitting. The channel threads stop sending
// heartbeats once this is false, which lets the sidecar detect heartbeat loss
// and shut itself down gracefully — the only graceful path on Windows, where
// there is no SIGTERM to deliver.
static HEARTBEAT_ACTIVE: AtomicBool = AtomicBool::new(true);

// Ensures a reload of the main page cannot repeat the startup transition.
static MAIN_REVEALED: AtomicBool = AtomicBool::new(false);

// Outbound side of the sidecar channel: heartbeats, replies, and native
// events (menu/tray clicks) are queued here and written by the writer thread.
static CHANNEL_TX: Mutex<Option<mpsc::Sender<String>>> = Mutex::new(None);

// Handle to the tray icon created via the "set_tray" channel command.
// Kept so a later set_tray replaces (drops) the previous icon.
static TRAY: Mutex<Option<tauri::tray::TrayIcon>> = Mutex::new(None);

struct AppState {
    sidecar_child: Mutex<Option<SidecarProcess>>,
}

struct SidecarProcess {
    child: Option<tauri_plugin_shell::process::CommandChild>,
    pid: Option<u32>,
}

impl Drop for SidecarProcess {
    fn drop(&mut self) {
        if let Some(child) = self.child.take() {
            let _ = child.kill();
        }
    }
}

fn send_channel_message(message: String) {
    if let Ok(guard) = CHANNEL_TX.lock() {
        if let Some(tx) = guard.as_ref() {
            let _ = tx.send(message);
        }
    }
}

fn persistent_window_state_flags() -> StateFlags {
    // Visibility belongs to the startup lifecycle: the main window must always
    // begin hidden behind the splash, regardless of how it exited last time.
    StateFlags::all() & !StateFlags::VISIBLE
}

// Forwards a native event (menu click, tray click, errors) to the Elixir
// sidecar, where ExTauri.Desktop delivers it to subscribed processes.
fn send_channel_event(name: &str, payload: serde_json::Value) {
    let message = serde_json::json!({"type": "event", "name": name, "payload": payload});
    send_channel_message(message.to_string());
}

fn kill_sidecar(app: &tauri::AppHandle) {
    // Persist window geometry FIRST, while the windows still exist.
    //
    // This call is load-bearing, not belt-and-braces. tauri-plugin-window-state
    // only updates an in-memory cache on `CloseRequested`/`Resized`/`Moved`; the
    // single place it writes the state file is its `RunEvent::Exit` handler
    // (lib.rs:503). Every exit path in this app is a hard `std::process::exit(0)`
    // — the menu Quit handler, and the `ExitRequested` handler, which calls
    // `api.prevent_exit()` and then exits from a timer thread. `RunEvent::Exit`
    // therefore never fires, so without this the plugin would restore state on
    // launch and never save any: silently a no-op, and indistinguishable from
    // working until you relaunch and the window is the wrong size.
    //
    // `kill_sidecar` is the one choke point all three exit paths share.
    // Keep this aligned with the plugin builder in main(): visibility is excluded
    // deliberately, while size, position, maximised and fullscreen state persist.
    if let Err(error) = app.save_window_state(persistent_window_state_flags()) {
        eprintln!("[window-state] failed to save: {}", error);
    }

    // Stop heartbeating first: the sidecar's ShutdownManager sees the heartbeat
    // stop and begins its own graceful shutdown while we wait below.
    HEARTBEAT_ACTIVE.store(false, Ordering::Relaxed);

    if let Some(state) = app.try_state::<AppState>() {
        if let Ok(mut guard) = state.sidecar_child.lock() {
            if let Some(mut process) = guard.take() {
                // Try graceful shutdown first with SIGTERM
                if let Some(pid) = process.pid {
                    println!("Attempting graceful shutdown of sidecar (PID: {})...", pid);

                    // Send SIGTERM for graceful shutdown
                    #[cfg(unix)]
                    {
                        use std::process::Command;
                        let _ = Command::new("kill")
                            .args(["-TERM", &pid.to_string()])
                            .output();

                        // Wait up to 2 seconds for graceful shutdown
                        let timeout = Duration::from_millis(2000);
                        let start = std::time::Instant::now();

                        while start.elapsed() < timeout {
                            // Check if process is still running
                            let status = Command::new("kill")
                                .args(["-0", &pid.to_string()])
                                .output();

                            if let Ok(output) = status {
                                if !output.status.success() {
                                    println!("Sidecar shut down gracefully");
                                    return;
                                }
                            }

                            std::thread::sleep(Duration::from_millis(100));
                        }

                        println!("Graceful shutdown timeout, forcing kill...");
                    }

                    #[cfg(windows)]
                    {
                        // No SIGTERM on Windows. The heartbeat was stopped above,
                        // so the sidecar's ShutdownManager times out (1500ms by
                        // default) and exits gracefully on its own — give it time
                        // to do so before falling through to the hard kill.
                        std::thread::sleep(Duration::from_millis(2000));
                    }
                }

                // Fallback to SIGKILL if graceful shutdown didn't work
                if let Some(child) = process.child.take() {
                    println!("Sending SIGKILL to sidecar...");
                    let _ = child.kill();
                }
            }
        }
    }
}

fn main() {
    tauri::Builder::default()
        .register_uri_scheme_protocol("armchair-splash", |_context, _request| {
            tauri::http::Response::builder()
                .header(
                    tauri::http::header::CONTENT_TYPE,
                    "text/html; charset=utf-8",
                )
                .header(
                    tauri::http::header::CONTENT_SECURITY_POLICY,
                    "default-src 'none'; style-src 'unsafe-inline'",
                )
                .body(splashscreen_html().into_bytes())
                .expect("the splashscreen response must be valid")
        })
        .plugin(tauri_plugin_single_instance::init(|_app, _args, _cwd| {
            // Focus the main window when a second instance is launched
        }))
        // Remembers window size, position and maximised state across launches.
        // The size in tauri.conf.json is only the FIRST-run default: once a state
        // file exists it wins, so resizing the window sticks.
        //
        // Registering it is necessary but NOT sufficient here — see the explicit
        // save in `kill_sidecar`, without which this plugin silently persists
        // nothing in this app.
        .plugin(
            tauri_plugin_window_state::Builder::default()
                .with_state_flags(persistent_window_state_flags())
                .with_denylist(&["splashscreen"])
                .build(),
        )
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_log::Builder::new().build())
        .plugin(tauri_plugin_notification::init())
        .manage(AppState {
            sidecar_child: Mutex::new(None),
        })
        .on_page_load(|webview, payload| {
            if main_page_ready(webview.label(), payload.event(), payload.url()) {
                reveal_main_window(webview.window().app_handle());
            }
        })
        // Tauri v2 installs no default macOS menu, so Cmd+Q is unbound. A *custom*
        // Quit item (not the predefined one, which terminates natively and bypasses
        // on_menu_event) routes Cmd+Q through on_menu_event -> kill_sidecar so the
        // backend is stopped before exit. The Edit submenu keeps copy/paste working.
        .menu(|handle| {
            let quit = MenuItem::with_id(handle, "quit", "Quit Armchair Metropolist", true, Some("CmdOrCtrl+Q"))?;
            let app_menu = Submenu::with_items(handle, "Armchair Metropolist", true, &[&quit])?;
            let edit_menu = Submenu::with_items(
                handle,
                "Edit",
                true,
                &[
                    &PredefinedMenuItem::undo(handle, None)?,
                    &PredefinedMenuItem::redo(handle, None)?,
                    &PredefinedMenuItem::separator(handle)?,
                    &PredefinedMenuItem::cut(handle, None)?,
                    &PredefinedMenuItem::copy(handle, None)?,
                    &PredefinedMenuItem::paste(handle, None)?,
                    &PredefinedMenuItem::select_all(handle, None)?,
                ],
            )?;
            Menu::with_items(handle, &[&app_menu, &edit_menu])
        })
        .setup(|app| {
            if let Err(error) = create_splashscreen(app) {
                eprintln!("[splashscreen] failed to create: {}", error);
            }

            let port = resolve_port();
            start_server(app.handle(), port);

            // HAND-EDITED. This file is generated by `mix ex_tauri.install`; keep
            // this change if it is ever regenerated.
            //
            // As generated, `check_server_started` was called straight from here.
            // `setup` runs on the main thread, so that blocks the macOS run loop for
            // as long as the sidecar takes to boot — about a second in a release.
            // Blocking the UI thread waiting on a socket is wrong regardless of what
            // it causes, so the wait now happens on a background thread and the
            // window is navigated once the port answers.
            //
            // The *navigate* must still happen on the main thread. macOS webviews
            // may only be driven from there, so calling navigate from the worker
            // silently leaves the window blank white — which is exactly what an
            // earlier revision of this comment block caused. Wait off-thread, then
            // hop back via run_on_main_thread to do the actual navigation.
            let nav_handle = app.handle().clone();
            std::thread::spawn(move || {
                check_server_started(port);

                let main_thread_handle = nav_handle.clone();

                let _ = nav_handle.run_on_main_thread(move || {
                    navigate_main_window(&main_thread_handle, port);
                });
            });

            start_channel(app.handle().clone());
            Ok(())
        })
        // Intercept menu events (especially CMD+Q on macOS)
        .on_menu_event(|app, event| {
            println!("Menu event received: {:?}", event.id());
            // On macOS, the default menu includes a "quit" item
            // Intercept it to perform graceful shutdown
            if event.id().as_ref() == "quit" || event.id().as_ref().contains("quit") {
                println!("Quit menu item clicked (CMD+Q), shutting down gracefully...");
                kill_sidecar(app);
                std::thread::sleep(std::time::Duration::from_millis(500));
                std::process::exit(0);
            }

            // Forward every other menu click to the Elixir sidecar so
            // server-side code can react (see ExTauri.Desktop.subscribe/0).
            send_channel_event(
                "menu_click",
                serde_json::json!({"id": event.id().as_ref()}),
            );
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { .. } = event {
                // Kill the sidecar when the main window closes. Secondary
                // windows (ExTauri.Window.open) close without stopping the app.
                if window.label() == "main" {
                    kill_sidecar(&window.app_handle());
                }
            }
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app_handle, event| {
            if let tauri::RunEvent::ExitRequested { api, .. } = event {
                // Kill the sidecar when the app is exiting (fallback for non-menu exits)
                println!("ExitRequested event received, shutting down...");
                kill_sidecar(app_handle);
                api.prevent_exit(); // Prevent exit until we've cleaned up
                // Allow exit after cleanup
                std::thread::spawn(move || {
                    std::thread::sleep(std::time::Duration::from_millis(500));
                    std::process::exit(0);
                });
            }
        });
}

fn splashscreen_html() -> String {
    include_str!("../splashscreen.html").replace("__ICON_SVG__", include_str!("../icons/icon.svg"))
}

fn splashscreen_url() -> tauri::Url {
    "armchair-splash://localhost/index.html"
        .parse()
        .expect("the embedded splashscreen must form a valid custom-protocol URL")
}

fn create_splashscreen(app: &tauri::App) -> tauri::Result<()> {
    WebviewWindowBuilder::new(
        app,
        "splashscreen",
        WebviewUrl::CustomProtocol(splashscreen_url()),
    )
        .title("Armchair Metropolist")
        .inner_size(920.0, 720.0)
        .resizable(false)
        .maximizable(false)
        .minimizable(false)
        .closable(false)
        .decorations(false)
        .skip_taskbar(true)
        .always_on_top(true)
        .shadow(true)
        .transparent(true)
        .background_color(Color(0, 0, 0, 0))
        .center()
        .build()?;

    Ok(())
}

fn main_page_ready(label: &str, event: PageLoadEvent, url: &tauri::Url) -> bool {
    label == "main"
        && event == PageLoadEvent::Finished
        && url.scheme() == "http"
        && url.host_str() == Some("127.0.0.1")
}

fn reveal_main_window(app: &tauri::AppHandle) {
    if MAIN_REVEALED.swap(true, Ordering::SeqCst) {
        return;
    }

    let Some(main) = app.get_webview_window("main") else {
        eprintln!("[splashscreen] cannot reveal missing main window");
        MAIN_REVEALED.store(false, Ordering::SeqCst);
        return;
    };

    if let Err(error) = main.show() {
        eprintln!("[splashscreen] failed to show main window: {}", error);
        MAIN_REVEALED.store(false, Ordering::SeqCst);
        return;
    }

    if let Some(splashscreen) = app.get_webview_window("splashscreen") {
        if let Err(error) = splashscreen.destroy() {
            eprintln!("[splashscreen] failed to close: {}", error);
        }
    }

    if let Err(error) = main.set_focus() {
        eprintln!("[splashscreen] failed to focus main window: {}", error);
    }
}

// Uses EX_TAURI_PORT when set (mix ex_tauri.dev pins it to the configured dev
// port); otherwise asks the OS for a free ephemeral port so installed apps
// never collide with other services. The sidecar receives the choice via the
// PORT env var and the window navigates to it once the server is up.
fn resolve_port() -> u16 {
    if let Ok(value) = std::env::var("EX_TAURI_PORT") {
        if let Ok(port) = value.parse::<u16>() {
            return port;
        }
    }

    std::net::TcpListener::bind(("127.0.0.1", 0))
        .and_then(|listener| listener.local_addr())
        .map(|addr| addr.port())
        .unwrap_or(4000)
}

// Phoenix releases sign session cookies with SECRET_KEY_BASE. Respect one if
// provided; otherwise generate a per-launch secret — sessions reset between
// launches, which is fine for a local desktop app.
fn secret_key_base() -> String {
    if let Ok(secret) = std::env::var("SECRET_KEY_BASE") {
        return secret;
    }

    #[cfg(unix)]
    {
        use std::io::Read;
        if let Ok(mut file) = std::fs::File::open("/dev/urandom") {
            let mut buf = [0u8; 48];
            if file.read_exact(&mut buf).is_ok() {
                return buf.iter().map(|b| format!("{:02x}", b)).collect();
            }
        }
    }

    // Fallback entropy: hash of time + pid. Weak, but only signs local
    // session cookies for a single-user desktop app.
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mut out = String::new();
    for round in 0..8u32 {
        let mut hasher = DefaultHasher::new();
        (nanos, std::process::id(), round).hash(&mut hasher);
        out.push_str(&format!("{:016x}", hasher.finish()));
    }
    out
}

fn start_server(app: &tauri::AppHandle, port: u16) {
    // PORT and SECRET_KEY_BASE are always injected: every server needs a port,
    // and SECRET_KEY_BASE is a random per-launch secret (inert if unused). The
    // remaining pairs come from `config :ex_tauri, :sidecar_env` — the Phoenix
    // defaults (PHX_SERVER/PHX_HOST) unless overridden for another framework.
    //
    // HAND-EDITED — THIS FILE IS GENERATED BY `mix ex_tauri.install`.
    // ARMCHAIR_DESKTOP below is ours, and it must survive any re-run of the
    // installer (which overwrites this file wholesale from its EEx template).
    //
    // `config :ex_tauri, :sidecar_env` cannot deliver it: that key is read only at
    // install time, to generate this very list (ex_tauri's install/helpers.ex,
    // sidecar_env/1). Our installer run predates the key, so the config entry is
    // inert and this literal is the only thing that sets the variable for a
    // Burrito sidecar. Without it, `desktop?` in config/runtime.exs is false in a
    // release and every desktop override silently reverts to the server target:
    // Repo started, Postgres snapshot store, LogNotifier, no ShutdownManager, and
    // no bounded connection drain — so no snapshot on window close.
    let env: std::collections::HashMap<String, String> = std::collections::HashMap::from([
        ("PORT".to_string(), port.to_string()),
        ("SECRET_KEY_BASE".to_string(), secret_key_base()),
        ("PHX_SERVER".to_string(), "true".to_string()),
        ("PHX_HOST".to_string(), "localhost".to_string()),
        ("ARMCHAIR_DESKTOP".to_string(), "1".to_string()),
    ]);

    // `--no-halt` is REQUIRED and ex_tauri does not pass it. Burrito launches the
    // release as `erl -noshell -s elixir start_cli ... -extra <args>`, and
    // `start_cli` treats the extra args as scripts to run and then HALTS. With no
    // args the sidecar therefore booted Phoenix, printed "Running ... Endpoint",
    // and exited 0 immediately — which is what a Mix release's own `start` command
    // avoids by passing this same flag. Everything downstream followed from it: the
    // port was never reachable, the heartbeat channel dropped, and the window stayed
    // white because there was nothing left to navigate to.
    let sidecar_command = app.shell().sidecar("desktop")
        .expect("failed to setup `desktop` sidecar")
        .args(["--no-halt"])
        .envs(env);

    let (mut rx, child) = sidecar_command
        .spawn()
        .expect("Failed to spawn desktop sidecar");

    // Get the PID for graceful shutdown
    let pid = child.pid();
    println!("Sidecar process started with PID: {}", pid);

    // Store the child process handle so we can kill it on exit
    if let Some(state) = app.try_state::<AppState>() {
        if let Ok(mut guard) = state.sidecar_child.lock() {
            *guard = Some(SidecarProcess {
                child: Some(child),
                pid: Some(pid),
            });
        }
    }

    tauri::async_runtime::spawn(async move {
        while let Some(event) = rx.recv().await {
            // As generated this matched only Stdout, so the sidecar's stderr and its
            // exit status were both discarded. A crashing sidecar therefore died in
            // total silence — the log showed Phoenix booting and then nothing, which
            // made it look like a webview or navigation problem for a long time.
            match event {
                CommandEvent::Stdout(bytes) => {
                    print!("{}", String::from_utf8_lossy(&bytes));
                }
                CommandEvent::Stderr(bytes) => {
                    eprint!("[sidecar stderr] {}", String::from_utf8_lossy(&bytes));
                }
                CommandEvent::Terminated(payload) => {
                    println!(
                        "[sidecar] TERMINATED code={:?} signal={:?}",
                        payload.code, payload.signal
                    );
                }
                CommandEvent::Error(message) => {
                    println!("[sidecar] ERROR {}", message);
                }
                _ => {}
            }
        }
    });
}

fn check_server_started(port: u16) {
    let sleep_interval = std::time::Duration::from_millis(200);
    // 127.0.0.1, NOT "localhost". On macOS localhost resolves ::1 first, and the
    // sidecar's Bandit binds 0.0.0.0 — IPv4 only — so the IPv6 attempt is refused.
    // This loop spun forever against a server that was up and listening.
    let addr = format!("127.0.0.1:{}", port);
    println!(
        "Waiting for your phoenix dev server to start on {}...",
        addr
    );
    let mut attempts = 0u32;
    loop {
        if std::net::TcpStream::connect(addr.clone()).is_ok() {
            // Instrumented: without this, a wait that never returns and a wait
            // that returns instantly look identical in the log.
            println!("[wait] {} accepted after {} attempt(s)", addr, attempts + 1);
            break;
        }
        attempts += 1;
        std::thread::sleep(sleep_interval);
    }
}

// Points the window at the port actually in use. When the OS assigned a free
// port (production), the compile-time URL in tauri.conf.json is wrong — and
// even in dev this reload recovers the webview if it raced the server boot.
fn navigate_main_window(app: &tauri::AppHandle, port: u16) {
    // Instrumented deliberately. Every failure mode in this function was silent:
    // a missing window, an unparseable URL and a failed navigate all did nothing
    // observable, which made a white window impossible to diagnose from the log.
    // 127.0.0.1 for the same reason as check_server_started: a webview told to
    // load http://localhost:PORT resolves ::1 first and gets connection refused,
    // which renders as a blank white window with no error anywhere.
    let url_string = format!("http://127.0.0.1:{}", port);

    let Some(window) = app.get_webview_window("main") else {
        println!("[navigate] FAILED: no webview window labelled \"main\"");
        return;
    };

    let parsed = match url_string.parse() {
        Ok(url) => url,
        Err(error) => {
            println!("[navigate] FAILED: {} did not parse: {}", url_string, error);
            return;
        }
    };

    match window.navigate(parsed) {
        Ok(()) => println!("[navigate] ok -> {}", url_string),
        Err(error) => println!("[navigate] FAILED: navigate({}) -> {}", url_string, error),
    }
}

// The sidecar channel carries heartbeats (liveness), commands from Elixir
// (ExTauri.Desktop: notifications, tray, ...), and native events back to
// Elixir — all as newline-delimited JSON over the ShutdownManager socket.
fn start_channel(app: tauri::AppHandle) {
    println!("Starting sidecar channel (heartbeat + desktop commands)...");

    std::thread::spawn(move || {
        let interval = Duration::from_millis(100);

        // Outer loop: (re)establish the connection. The sidecar's listener can
        // come up late (slow boot) or be recreated, so a dropped connection must
        // reconnect rather than end the heartbeat — otherwise the backend would
        // see the heartbeat stop and shut itself down. Everything exits once
        // HEARTBEAT_ACTIVE is cleared (the app is quitting): stopping the
        // heartbeat is what tells the sidecar to shut down gracefully.
        while HEARTBEAT_ACTIVE.load(Ordering::Relaxed) {
            let stream = match connect_channel() {
                Some(stream) => stream,
                None => return,
            };

            println!("Connected to sidecar channel");

            let (tx, rx) = mpsc::channel::<String>();
            if let Ok(mut guard) = CHANNEL_TX.lock() {
                *guard = Some(tx.clone());
            }

            // Ticker: queue a heartbeat line every 100ms.
            let ticker_tx = tx.clone();
            std::thread::spawn(move || {
                while HEARTBEAT_ACTIVE.load(Ordering::Relaxed) {
                    if ticker_tx
                        .send(String::from("{\"type\":\"heartbeat\"}"))
                        .is_err()
                    {
                        break;
                    }
                    std::thread::sleep(interval);
                }
            });

            // Reader: executes desktop commands sent by Elixir.
            if let Ok(read_stream) = stream.try_clone() {
                let reader_app = app.clone();
                std::thread::spawn(move || {
                    use std::io::{BufRead, BufReader};
                    let reader = BufReader::new(read_stream);
                    for line in reader.lines() {
                        match line {
                            Ok(line) => handle_channel_command(&reader_app, &line),
                            Err(_) => break,
                        }
                    }
                });
            }

            // Writer (this thread): drain the queue onto the socket. A failed
            // write means the connection dropped — clean up and reconnect.
            let mut stream = stream;
            for message in rx.iter() {
                if writeln!(stream, "{}", message).is_err() {
                    break;
                }
            }

            if let Ok(mut guard) = CHANNEL_TX.lock() {
                *guard = None;
            }

            if HEARTBEAT_ACTIVE.load(Ordering::Relaxed) {
                println!("Sidecar channel lost, reconnecting...");
            }
        }
    });
}

#[cfg(unix)]
type ChannelStream = std::os::unix::net::UnixStream;
#[cfg(windows)]
type ChannelStream = std::net::TcpStream;

// Connects to the ShutdownManager's listener, retrying until the sidecar is
// up. Returns None only when the app is shutting down.
fn connect_channel() -> Option<ChannelStream> {
    #[cfg(unix)]
    {
        use std::os::unix::net::UnixStream;

        let socket_path = std::env::temp_dir().join("tauri_heartbeat_armchair_metropolist.sock");

        loop {
            if !HEARTBEAT_ACTIVE.load(Ordering::Relaxed) {
                return None;
            }
            match UnixStream::connect(&socket_path) {
                Ok(stream) => return Some(stream),
                Err(_) => std::thread::sleep(Duration::from_millis(100)),
            }
        }
    }

    #[cfg(windows)]
    {
        use std::net::TcpStream;

        // The BEAM cannot listen on Unix domain sockets on Windows, so the
        // sidecar listens on 127.0.0.1 with an OS-assigned port and publishes
        // the port number in this discovery file (see ExTauri.ShutdownManager).
        // Re-read it on every reconnect: the port changes when the sidecar
        // restarts its listener.
        let port_file = std::env::temp_dir().join("tauri_heartbeat_armchair_metropolist.port");

        loop {
            if !HEARTBEAT_ACTIVE.load(Ordering::Relaxed) {
                return None;
            }
            let port = std::fs::read_to_string(&port_file)
                .ok()
                .and_then(|contents| contents.trim().parse::<u16>().ok());
            match port.and_then(|p| TcpStream::connect(("127.0.0.1", p)).ok()) {
                Some(stream) => return Some(stream),
                None => std::thread::sleep(Duration::from_millis(100)),
            }
        }
    }
}

// Executes a desktop command sent by the Elixir sidecar (ExTauri.Desktop).
fn handle_channel_command(app: &tauri::AppHandle, line: &str) {
    let parsed: serde_json::Value = match serde_json::from_str(line) {
        Ok(value) => value,
        Err(_) => return,
    };

    if parsed["type"] != "command" {
        return;
    }

    let name = parsed["name"].as_str().unwrap_or("").to_string();
    let payload = parsed["payload"].clone();

    match name.as_str() {
        "notify" => {
            use tauri_plugin_notification::NotificationExt;
            let title = payload["title"].as_str().unwrap_or("Notification").to_string();
            let body = payload["body"].as_str().unwrap_or("").to_string();
            let _ = app.notification().builder().title(title).body(body).show();
        }

        "set_tray" => {
            let app_handle = app.clone();
            let _ = app.run_on_main_thread(move || set_tray(&app_handle, payload));
        }

        other => {
            send_channel_event(
                "error",
                serde_json::json!({"message": format!("Unknown desktop command: {}", other)}),
            );
        }
    }
}

// Builds (or replaces) the system tray from an Elixir-provided spec:
// {"tooltip": "...", "items": [{"id": "...", "label": "..."}, ...]}.
// Menu item clicks come back as "tray_menu_click" events on the channel.
fn set_tray(app: &tauri::AppHandle, payload: serde_json::Value) {
    use tauri::tray::TrayIconBuilder;

    let empty = Vec::new();
    let item_specs = payload["items"].as_array().unwrap_or(&empty);

    let mut items: Vec<MenuItem<tauri::Wry>> = Vec::new();
    for spec in item_specs {
        let id = spec["id"].as_str().unwrap_or("item");
        let label = spec["label"].as_str().unwrap_or(id);
        if let Ok(item) = MenuItem::with_id(app, id, label, true, None::<&str>) {
            items.push(item);
        }
    }

    let item_refs: Vec<&dyn tauri::menu::IsMenuItem<tauri::Wry>> = items
        .iter()
        .map(|item| item as &dyn tauri::menu::IsMenuItem<tauri::Wry>)
        .collect();

    let menu = match Menu::with_items(app, &item_refs) {
        Ok(menu) => menu,
        Err(error) => {
            send_channel_event(
                "error",
                serde_json::json!({"message": format!("Failed to build tray menu: {}", error)}),
            );
            return;
        }
    };

    let mut builder = TrayIconBuilder::with_id("ex_tauri_tray")
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(|_app, event| {
            send_channel_event(
                "tray_menu_click",
                serde_json::json!({"id": event.id().as_ref()}),
            );
        });

    if let Some(tooltip) = payload["tooltip"].as_str() {
        builder = builder.tooltip(tooltip);
    }

    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }

    match builder.build(app) {
        Ok(tray) => {
            if let Ok(mut guard) = TRAY.lock() {
                // Dropping the previous handle removes its icon.
                *guard = Some(tray);
            }
        }
        Err(error) => {
            send_channel_event(
                "error",
                serde_json::json!({"message": format!("Failed to build tray: {}", error)}),
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_finished_loopback_main_page_is_ready() {
        let ready: tauri::Url = "http://127.0.0.1:41234/".parse().unwrap();
        let compile_time_url: tauri::Url = "http://localhost:4000/".parse().unwrap();

        assert!(main_page_ready("main", PageLoadEvent::Finished, &ready));
        assert!(!main_page_ready("main", PageLoadEvent::Started, &ready));
        assert!(!main_page_ready(
            "secondary",
            PageLoadEvent::Finished,
            &ready
        ));
        assert!(!main_page_ready(
            "main",
            PageLoadEvent::Finished,
            &compile_time_url
        ));
    }

    #[test]
    fn splashscreen_is_a_self_contained_document() {
        let url = splashscreen_url();

        assert_eq!(url.scheme(), "armchair-splash");
        assert_eq!(url.host_str(), Some("localhost"));
    }

    #[test]
    fn splashscreen_document_embeds_the_project_icon() {
        let html = splashscreen_html();

        assert!(!html.contains("__ICON_SVG__"));
        assert!(html.contains("<svg"));
        assert!(html.contains("Acquiring construction permits..."));
        assert!(html.contains("background: transparent"));
    }
}
