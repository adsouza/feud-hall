mod crash_reports;
mod diagnostics;
mod native_events;
mod transport;

use crash_reports::{ReportSummary, Session};
use diagnostics::{Breadcrumbs, Source, WebviewCrumb, LOG_CAP};
use serde_json::{Map, Value};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;
use tauri::webview::NewWindowResponse;
use tauri::{App, Manager, RunEvent, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_window_state::StateFlags;
use transport::{HallClient, Request, Response};

/// Crash breadcrumbs for this session. Every part is optional: a log folder
/// that cannot be used turns diagnostics off, never the game.
struct Diagnostics {
    dir: Option<PathBuf>,
    crumbs: Breadcrumbs,
    session: Mutex<Option<Session>>,
}

#[tauri::command]
async fn hall_request(
    client: tauri::State<'_, HallClient>,
    request: Request,
) -> Result<Response, &'static str> {
    client.send(request).await
}

#[tauri::command]
fn diagnostic_breadcrumb(diagnostics: tauri::State<'_, Diagnostics>, crumb: WebviewCrumb) {
    diagnostics.crumbs.record_webview(crumb);
}

#[tauri::command]
fn crash_reports(diagnostics: tauri::State<'_, Diagnostics>) -> Vec<ReportSummary> {
    diagnostics
        .dir
        .as_deref()
        .map(crash_reports::pending)
        .unwrap_or_default()
}

#[tauri::command]
fn acknowledge_crash_reports(diagnostics: tauri::State<'_, Diagnostics>) {
    if let Some(dir) = &diagnostics.dir {
        crash_reports::acknowledge(dir);
    }
}

/// Shows the newest report in the system file manager. Inside a Flatpak the
/// runtime's `xdg-open` goes through the OpenURI portal.
#[tauri::command]
fn reveal_crash_report(diagnostics: tauri::State<'_, Diagnostics>) -> Result<(), &'static str> {
    let dir = diagnostics.dir.as_deref().ok_or("reveal_unavailable")?;
    let newest = crash_reports::pending(dir)
        .into_iter()
        .next()
        .ok_or("reveal_unavailable")?;
    let mut command = reveal_command(dir, Path::new(&newest.path));
    let mut child = command.spawn().map_err(|_| "reveal_unavailable")?;
    std::thread::spawn(move || child.wait());
    Ok(())
}

#[cfg(target_os = "macos")]
fn reveal_command(_dir: &Path, report: &Path) -> Command {
    let mut command = Command::new("open");
    command.arg("-R").arg(report);
    command
}

#[cfg(not(target_os = "macos"))]
fn reveal_command(dir: &Path, _report: &Path) -> Command {
    let mut command = Command::new("xdg-open");
    command.arg(dir);
    command
}

/// Starts this session's log after turning any session that died into a
/// crash report.
fn start_diagnostics(app: &App) -> Diagnostics {
    let dir = app.path().app_log_dir().ok();
    let id = crash_reports::session_id(time::OffsetDateTime::now_utc(), std::process::id());
    let session = dir
        .as_deref()
        .and_then(|dir| crash_reports::start(dir, &id).ok());
    let Some(session) = session else {
        return Diagnostics {
            dir,
            crumbs: Breadcrumbs::disabled(),
            session: Mutex::new(None),
        };
    };
    if let Some(dir) = &dir {
        crash_reports::collect(dir, &id, std::env::consts::OS);
    }
    let crumbs = Breadcrumbs::open(&session.log, LOG_CAP);
    let mut fields = Map::new();
    fields.insert(
        "app_version".into(),
        app.package_info().version.to_string().into(),
    );
    fields.insert("os".into(), std::env::consts::OS.into());
    fields.extend(diagnostics::environment_from(
        std::env::vars(),
        std::fs::read_to_string("/.flatpak-info").ok().as_deref(),
    ));
    #[cfg(target_os = "linux")]
    fields.extend(native_events::linux::toolkit_versions());
    crumbs.record(Source::Native, "session_started", fields);
    Diagnostics {
        dir,
        crumbs,
        session: Mutex::new(Some(session)),
    }
}

fn main() {
    let origin = option_env!("FEUD_HALL_NATIVE_ORIGIN").unwrap_or("http://localhost:4000");
    let client = HallClient::new(origin).expect("invalid Feud Hall server origin");
    tauri::Builder::default()
        .plugin(
            tauri_plugin_window_state::Builder::default()
                .with_state_flags(StateFlags::SIZE | StateFlags::POSITION | StateFlags::MAXIMIZED)
                .build(),
        )
        .manage(client)
        .invoke_handler(tauri::generate_handler![
            hall_request,
            diagnostic_breadcrumb,
            crash_reports,
            acknowledge_crash_reports,
            reveal_crash_report
        ])
        .on_window_event(|window, event| {
            if let (Some((name, fields)), Some(diagnostics)) = (
                native_events::crumb_for(event),
                window.try_state::<Diagnostics>(),
            ) {
                diagnostics.crumbs.record(Source::Native, name, fields);
            }
        })
        .setup(|app| {
            let diagnostics = start_diagnostics(app);
            #[cfg(target_os = "linux")]
            native_events::linux::watch_selections(diagnostics.crumbs.clone());
            app.manage(diagnostics);
            WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
                .title("Feud Hall")
                .inner_size(1280.0, 850.0)
                .min_inner_size(360.0, 500.0)
                .zoom_hotkeys_enabled(false)
                .initialization_script(
                    include_str!("zoom.js").replace("__FEUD_OS__", std::env::consts::OS),
                )
                .initialization_script(include_str!("diagnostics.js"))
                .on_navigation(|url| {
                    url.scheme() == "tauri"
                        && url.host_str() == Some("localhost")
                        && url.port().is_none()
                        && url.username().is_empty()
                        && url.password().is_none()
                })
                .on_new_window(|_, _| NewWindowResponse::Deny)
                .build()?;
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("build the Feud Hall desktop client")
        .run(|app, event| {
            if let RunEvent::Exit = event {
                if let Some(diagnostics) = app.try_state::<Diagnostics>() {
                    diagnostics.crumbs.record(
                        Source::Native,
                        "session_exit",
                        Map::<String, Value>::new(),
                    );
                    let session = diagnostics.session.lock().ok().and_then(|mut s| s.take());
                    if let Some(session) = session {
                        session.finish();
                    }
                }
            }
        });
}
