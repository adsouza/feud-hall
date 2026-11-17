//! Native events written to the breadcrumb log.
use serde_json::{json, Map, Value};
use tauri::WindowEvent;

fn object(value: Value) -> Map<String, Value> {
    match value {
        Value::Object(map) => map,
        _ => Map::new(),
    }
}

/// The breadcrumb for a window event, if it is worth one. Moves are left
/// out: dragging a window produces them every frame.
pub fn crumb_for(event: &WindowEvent) -> Option<(&'static str, Map<String, Value>)> {
    let (name, fields) = match event {
        WindowEvent::Focused(focused) => ("window_focus", json!({ "focused": focused })),
        WindowEvent::Resized(size) => (
            "window_resized",
            json!({ "width": size.width, "height": size.height }),
        ),
        WindowEvent::ScaleFactorChanged {
            scale_factor,
            new_inner_size,
            ..
        } => (
            "window_scale_changed",
            json!({
                "scale_factor": scale_factor,
                "width": new_inner_size.width,
                "height": new_inner_size.height,
            }),
        ),
        WindowEvent::CloseRequested { .. } => ("window_close_requested", json!({})),
        WindowEvent::Destroyed => ("window_destroyed", json!({})),
        _ => return None,
    };
    Some((name, object(fields)))
}

#[cfg(target_os = "linux")]
pub mod linux {
    use crate::diagnostics::{Breadcrumbs, Source};
    use gtk::prelude::*;
    use serde_json::{json, Map, Value};

    /// GTK and WebKitGTK versions as loaded at run time (inside a Flatpak,
    /// the runtime's, not the build machine's). Call on the main thread.
    pub fn toolkit_versions() -> Map<String, Value> {
        // SAFETY: plain getters with no arguments or preconditions.
        let webkit = unsafe {
            format!(
                "{}.{}.{}",
                webkit2gtk::ffi::webkit_get_major_version(),
                webkit2gtk::ffi::webkit_get_minor_version(),
                webkit2gtk::ffi::webkit_get_micro_version()
            )
        };
        let gtk = format!(
            "{}.{}.{}",
            gtk::major_version(),
            gtk::minor_version(),
            gtk::micro_version()
        );
        super::object(json!({ "gtk_version": gtk, "webkit_version": webkit }))
    }

    /// Records when another program takes the clipboard or the primary
    /// selection: only that ownership changed, never what was copied.
    pub fn watch_selections(crumbs: Breadcrumbs) {
        for (atom, name) in [
            (gdk::SELECTION_CLIPBOARD, "clipboard"),
            (gdk::SELECTION_PRIMARY, "primary"),
        ] {
            let clipboard = gtk::Clipboard::get(&atom);
            let crumbs = crumbs.clone();
            // gtk-rs 0.18 generates no typed owner-change binding.
            clipboard.connect_local("owner-change", false, move |values| {
                let reason = values
                    .get(1)
                    .and_then(|value| value.get::<gdk::Event>().ok())
                    .and_then(|event| {
                        event.downcast_ref::<gdk::EventOwnerChange>().map(|change| {
                            match change.reason() {
                                gdk::OwnerChange::NewOwner => "new_owner",
                                gdk::OwnerChange::Destroy => "destroy",
                                gdk::OwnerChange::Close => "close",
                                _ => "other",
                            }
                        })
                    })
                    .unwrap_or("unknown");
                crumbs.record(
                    Source::Native,
                    "selection_owner_changed",
                    super::object(json!({ "selection": name, "reason": reason })),
                );
                None
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tauri::{PhysicalPosition, PhysicalSize};

    #[test]
    fn window_events_map_to_breadcrumbs() {
        let (event, fields) = crumb_for(&WindowEvent::Focused(false)).unwrap();
        assert_eq!(event, "window_focus");
        assert_eq!(Value::Object(fields), json!({"focused": false}));

        let (event, fields) =
            crumb_for(&WindowEvent::Resized(PhysicalSize::new(800, 600))).unwrap();
        assert_eq!(event, "window_resized");
        assert_eq!(Value::Object(fields), json!({"width": 800, "height": 600}));

        assert!(crumb_for(&WindowEvent::Moved(PhysicalPosition::new(4, 4))).is_none());
    }
}
