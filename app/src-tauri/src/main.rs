mod diagnostics;
mod transport;

use tauri::webview::NewWindowResponse;
use tauri::{WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_window_state::StateFlags;
use transport::{HallClient, Request, Response};

#[tauri::command]
async fn hall_request(
    client: tauri::State<'_, HallClient>,
    request: Request,
) -> Result<Response, &'static str> {
    client.send(request).await
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
        .invoke_handler(tauri::generate_handler![hall_request])
        .setup(|app| {
            WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
                .title("Feud Hall")
                .inner_size(1280.0, 850.0)
                .min_inner_size(360.0, 500.0)
                .zoom_hotkeys_enabled(false)
                .initialization_script(
                    include_str!("zoom.js").replace("__FEUD_OS__", std::env::consts::OS),
                )
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
        .run(tauri::generate_context!())
        .expect("run the Feud Hall desktop client");
}
