//! Desktop crash breadcrumbs: one JSON Lines file per session, written as
//! events happen so a hard crash loses at most the record being written.
//! Diagnostics never fail the game: any I/O error turns them off.
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Instant;
use time::macros::format_description;
use time::OffsetDateTime;

pub const LOG_CAP: u64 = 256 * 1024;
const WEBVIEW_PER_SECOND: u32 = 20;

/// The only things the page can report. Unknown kinds and extra fields are
/// refused, so the page has no way to write arbitrary text to the log. The
/// field-less kinds are empty struct variants: serde ignores extra fields on
/// unit variants even with `deny_unknown_fields`.
#[derive(Deserialize, Debug)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum WebviewCrumb {
    Visibility {
        visible: bool,
    },
    Focus {
        focused: bool,
    },
    Copy {},
    Cut {},
    Selection {
        length: u32,
    },
    WebglLost {},
    WebglRestored {},
    Error {
        message: String,
        file: String,
        line: u32,
    },
    Rejection {
        message: String,
    },
    Gpu {
        vendor: String,
        renderer: String,
    },
}

fn clip(text: &str, limit: usize) -> String {
    text.chars().take(limit).collect()
}

impl WebviewCrumb {
    fn record(self) -> (&'static str, Value) {
        match self {
            WebviewCrumb::Visibility { visible } => {
                ("webview_visibility", json!({ "visible": visible }))
            }
            WebviewCrumb::Focus { focused } => ("webview_focus", json!({ "focused": focused })),
            WebviewCrumb::Copy {} => ("webview_copy", json!({})),
            WebviewCrumb::Cut {} => ("webview_cut", json!({})),
            WebviewCrumb::Selection { length } => {
                ("webview_selection", json!({ "length": length }))
            }
            WebviewCrumb::WebglLost {} => ("webview_webgl_lost", json!({})),
            WebviewCrumb::WebglRestored {} => ("webview_webgl_restored", json!({})),
            WebviewCrumb::Error {
                message,
                file,
                line,
            } => (
                "webview_error",
                json!({
                    "message": clip(&message, 300),
                    "file": clip(file.rsplit('/').next().unwrap_or_default(), 120),
                    "line": line,
                }),
            ),
            WebviewCrumb::Rejection { message } => (
                "webview_rejection",
                json!({ "message": clip(&message, 300) }),
            ),
            WebviewCrumb::Gpu { vendor, renderer } => (
                "webview_gpu",
                json!({ "vendor": clip(&vendor, 200), "renderer": clip(&renderer, 200) }),
            ),
        }
    }
}

#[derive(Clone, Copy)]
pub enum Source {
    Native,
    Webview,
}

impl Source {
    fn name(self) -> &'static str {
        match self {
            Source::Native => "native",
            Source::Webview => "webview",
        }
    }
}

#[derive(Clone)]
pub struct Breadcrumbs {
    inner: Option<Arc<Inner>>,
}

struct Inner {
    started: Instant,
    state: Mutex<State>,
}

struct State {
    file: Option<File>,
    written: u64,
    cap: u64,
    truncated: bool,
    window: u64,
    in_window: u32,
    dropped: u64,
}

pub fn utc_timestamp(at: OffsetDateTime) -> String {
    at.format(format_description!(
        "[year]-[month]-[day]T[hour]:[minute]:[second].[subsecond digits:3]Z"
    ))
    .unwrap_or_default()
}

impl Breadcrumbs {
    pub fn open(path: &Path, cap: u64) -> Breadcrumbs {
        let opened = path
            .parent()
            .map_or(Ok(()), fs::create_dir_all)
            .and_then(|()| OpenOptions::new().create(true).append(true).open(path));
        let Ok(file) = opened else {
            return Breadcrumbs::disabled();
        };
        let written = file.metadata().map(|meta| meta.len()).unwrap_or(0);
        Breadcrumbs {
            inner: Some(Arc::new(Inner {
                started: Instant::now(),
                state: Mutex::new(State {
                    file: Some(file),
                    written,
                    cap,
                    truncated: false,
                    window: 0,
                    in_window: 0,
                    dropped: 0,
                }),
            })),
        }
    }

    pub fn disabled() -> Breadcrumbs {
        Breadcrumbs { inner: None }
    }

    pub fn is_enabled(&self) -> bool {
        self.inner.as_ref().is_some_and(|inner| {
            inner
                .state
                .lock()
                .map(|state| state.file.is_some())
                .unwrap_or(false)
        })
    }

    pub fn record(&self, source: Source, event: &str, fields: Map<String, Value>) {
        let Some(inner) = &self.inner else { return };
        let Ok(mut state) = inner.state.lock() else {
            return;
        };
        let line = inner.line(source, event, fields);
        if state.written + line.len() as u64 > state.cap {
            if !state.truncated {
                state.truncated = true;
                let notice = inner.line(Source::Native, "log_truncated", Map::new());
                state.write(&notice);
            }
            return;
        }
        state.write(&line);
    }
}

impl Breadcrumbs {
    pub fn record_webview(&self, crumb: WebviewCrumb) {
        let window = self
            .inner
            .as_ref()
            .map_or(0, |inner| inner.started.elapsed().as_secs());
        self.record_webview_at(crumb, window);
    }

    /// Rate-limits by one-second window; a window that dropped records is
    /// reported, with its count, before the next accepted record.
    fn record_webview_at(&self, crumb: WebviewCrumb, window: u64) {
        let Some(inner) = &self.inner else { return };
        let dropped = {
            let Ok(mut state) = inner.state.lock() else {
                return;
            };
            let mut dropped = 0;
            if state.window != window {
                state.window = window;
                state.in_window = 0;
                dropped = std::mem::take(&mut state.dropped);
            }
            if state.in_window >= WEBVIEW_PER_SECOND {
                state.dropped += 1;
                return;
            }
            state.in_window += 1;
            dropped
        };
        if dropped > 0 {
            self.record(
                Source::Webview,
                "webview_rate_limited",
                fields(json!({ "dropped": dropped })),
            );
        }
        let (event, data) = crumb.record();
        self.record(Source::Webview, event, fields(data));
    }
}

fn fields(value: Value) -> Map<String, Value> {
    match value {
        Value::Object(map) => map,
        _ => Map::new(),
    }
}

impl Inner {
    fn line(&self, source: Source, event: &str, fields: Map<String, Value>) -> String {
        let mut record = Map::new();
        record.insert("v".into(), 1.into());
        record.insert("at".into(), utc_timestamp(OffsetDateTime::now_utc()).into());
        record.insert(
            "elapsed_ms".into(),
            (self.started.elapsed().as_millis() as u64).into(),
        );
        record.insert("source".into(), source.name().into());
        record.insert("event".into(), event.into());
        for (key, value) in fields {
            record.entry(key).or_insert(value);
        }
        let mut line = Value::Object(record).to_string();
        line.push('\n');
        line
    }
}

impl State {
    fn write(&mut self, line: &str) {
        let Some(file) = &mut self.file else { return };
        // One write per record: the kernel keeps it if the process dies next.
        if file.write_all(line.as_bytes()).is_err() {
            self.file = None;
        } else {
            self.written += line.len() as u64;
        }
    }
}

/// The session's environment, limited to an allowlist: no paths, user names
/// or unrelated variables reach the log.
pub fn environment_from(
    vars: impl IntoIterator<Item = (String, String)>,
    flatpak_info: Option<&str>,
) -> Map<String, Value> {
    let mut environment = Map::new();
    let mut webkit = Map::new();
    let mut wayland = false;
    let mut x11 = false;
    for (key, value) in vars {
        match key.as_str() {
            "XDG_SESSION_TYPE" => {
                environment.insert("session_type".into(), value.into());
            }
            "GDK_BACKEND" => {
                environment.insert("gdk_backend".into(), value.into());
            }
            "WAYLAND_DISPLAY" => wayland = !value.is_empty(),
            "DISPLAY" => x11 = !value.is_empty(),
            _ if key.starts_with("WEBKIT_") => {
                webkit.insert(key, value.into());
            }
            _ => {}
        }
    }
    environment.insert("wayland_display_set".into(), wayland.into());
    environment.insert("x11_display_set".into(), x11.into());
    environment.insert("webkit_env".into(), Value::Object(webkit));
    if let Some(runtime) = flatpak_info
        .into_iter()
        .flat_map(str::lines)
        .find_map(|line| line.strip_prefix("runtime="))
    {
        environment.insert("flatpak_runtime".into(), runtime.trim().into());
    }
    environment
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Map, Value};
    use std::path::PathBuf;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "feud-hall-diagnostics-{name}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn lines(path: &std::path::Path) -> Vec<Value> {
        std::fs::read_to_string(path)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }

    fn fields(value: Value) -> Map<String, Value> {
        value.as_object().unwrap().clone()
    }

    #[test]
    fn record_writes_one_json_line_per_call() {
        let path = scratch("lines").join("logs/session.jsonl");
        let crumbs = Breadcrumbs::open(&path, LOG_CAP);
        assert!(crumbs.is_enabled());
        crumbs.record(
            Source::Native,
            "window_focus",
            fields(json!({"focused": false})),
        );
        crumbs.record(Source::Webview, "webview_copy", Map::new());

        let written = lines(&path);
        assert_eq!(written.len(), 2);
        assert_eq!(written[0]["v"], 1);
        assert_eq!(written[0]["source"], "native");
        assert_eq!(written[0]["event"], "window_focus");
        assert_eq!(written[0]["focused"], false);
        assert!(written[0]["at"].as_str().unwrap().ends_with('Z'));
        assert!(written[0]["elapsed_ms"].is_u64());
        assert_eq!(written[1]["source"], "webview");
        assert_eq!(written[1]["event"], "webview_copy");
    }

    #[test]
    fn cap_writes_log_truncated_once() {
        let path = scratch("cap").join("session.jsonl");
        let crumbs = Breadcrumbs::open(&path, 600);
        for index in 0..50 {
            crumbs.record(
                Source::Native,
                "window_resized",
                fields(json!({"width": index})),
            );
        }
        let text = std::fs::read_to_string(&path).unwrap();
        let longest = text.lines().map(str::len).max().unwrap() as u64 + 1;
        assert!(text.len() as u64 <= 600 + longest, "{} bytes", text.len());
        let truncated = lines(&path)
            .iter()
            .filter(|line| line["event"] == "log_truncated")
            .count();
        assert_eq!(truncated, 1);
    }

    #[test]
    fn unwritable_path_is_disabled() {
        let blocker = scratch("blocked").join("not-a-folder");
        std::fs::write(&blocker, "file").unwrap();
        let crumbs = Breadcrumbs::open(&blocker.join("session.jsonl"), LOG_CAP);
        assert!(!crumbs.is_enabled());
        crumbs.record(Source::Native, "window_focus", Map::new());
        assert!(!Breadcrumbs::disabled().is_enabled());
    }

    #[test]
    fn environment_keeps_only_allowlist() {
        let vars = [
            ("XDG_SESSION_TYPE", "wayland"),
            ("WAYLAND_DISPLAY", "wayland-0"),
            ("WEBKIT_DISABLE_DMABUF_RENDERER", "1"),
            ("FEUD_SECRET", "hunter2"),
            ("HOME", "/home/ria"),
        ]
        .map(|(key, value)| (key.to_string(), value.to_string()));
        let environment = environment_from(
            vars,
            Some("[Application]\nruntime=runtime/org.gnome.Platform/x86_64/50\n"),
        );
        assert_eq!(environment["session_type"], "wayland");
        assert_eq!(environment["wayland_display_set"], true);
        assert_eq!(environment["x11_display_set"], false);
        assert_eq!(
            environment["webkit_env"]["WEBKIT_DISABLE_DMABUF_RENDERER"],
            "1"
        );
        assert_eq!(
            environment["flatpak_runtime"],
            "runtime/org.gnome.Platform/x86_64/50"
        );
        let serialized = serde_json::to_string(&environment).unwrap();
        assert!(!serialized.contains("hunter2"));
        assert!(!serialized.contains("/home/ria"));
    }

    #[test]
    fn unknown_kind_and_extra_field_are_rejected() {
        assert!(serde_json::from_value::<WebviewCrumb>(json!({"kind": "paste"})).is_err());
        assert!(
            serde_json::from_value::<WebviewCrumb>(json!({"kind": "copy", "text": "x"})).is_err()
        );
        assert!(serde_json::from_value::<WebviewCrumb>(
            json!({"kind": "selection", "length": 3, "text": "abc"})
        )
        .is_err());
        assert!(serde_json::from_value::<WebviewCrumb>(json!({"kind": "copy"})).is_ok());
    }

    #[test]
    fn error_message_is_truncated_to_300_chars() {
        let path = scratch("truncate").join("session.jsonl");
        let crumbs = Breadcrumbs::open(&path, LOG_CAP);
        crumbs.record_webview(WebviewCrumb::Error {
            message: "日本語".repeat(400),
            file: "tauri://localhost/assets/index-abc.js".into(),
            line: 7,
        });
        let written = lines(&path);
        assert_eq!(written[0]["event"], "webview_error");
        assert_eq!(written[0]["message"].as_str().unwrap().chars().count(), 300);
        assert_eq!(written[0]["file"], "index-abc.js");
        assert_eq!(written[0]["line"], 7);
    }

    #[test]
    fn rate_limit_drops_and_reports() {
        let path = scratch("rate").join("session.jsonl");
        let crumbs = Breadcrumbs::open(&path, LOG_CAP);
        for _ in 0..25 {
            crumbs.record_webview_at(WebviewCrumb::Copy {}, 10);
        }
        crumbs.record_webview_at(WebviewCrumb::Cut {}, 11);
        let events: Vec<String> = lines(&path)
            .iter()
            .map(|line| line["event"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(events.iter().filter(|e| *e == "webview_copy").count(), 20);
        assert_eq!(events[20], "webview_rate_limited");
        assert_eq!(lines(&path)[20]["dropped"], 5);
        assert_eq!(events[21], "webview_cut");
        assert_eq!(events.len(), 22);
    }
}
