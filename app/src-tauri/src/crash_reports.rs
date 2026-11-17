//! Session markers and crash reports. Each running session holds an
//! exclusive lock on its marker; the kernel drops the lock when the process
//! dies, so a marker that can be locked belongs to a session that ended
//! without a clean exit. PIDs are not used: a Flatpak's PID is namespaced.
use serde::Serialize;
use serde_json::{Map, Value};
use std::fs::{self, File, OpenOptions, TryLockError};
use std::io;
use std::path::{Path, PathBuf};
use time::macros::format_description;
use time::OffsetDateTime;

const KEEP_REPORTS: usize = 5;
const KEEP_LOGS: usize = 5;
const SUMMARY_RECORDS: usize = 40;
const BASE_FIELDS: [&str; 5] = ["v", "at", "elapsed_ms", "source", "event"];

pub fn session_id(now: OffsetDateTime, pid: u32) -> String {
    let stamp = now
        .format(format_description!(
            "[year][month][day]T[hour][minute][second].[subsecond digits:3]Z"
        ))
        .unwrap_or_default();
    format!("{stamp}-{pid}")
}

pub struct Session {
    pub id: String,
    pub log: PathBuf,
    dir: PathBuf,
    // Held, locked, for the life of the process.
    _marker: File,
}

fn marker_path(dir: &Path, id: &str) -> PathBuf {
    dir.join(format!("session-{id}.marker"))
}
fn log_path(dir: &Path, id: &str) -> PathBuf {
    dir.join(format!("session-{id}.jsonl"))
}
fn report_path(dir: &Path, id: &str) -> PathBuf {
    dir.join(format!("crash-{id}.txt"))
}
fn seen_path(dir: &Path, id: &str) -> PathBuf {
    dir.join(format!("crash-{id}.seen"))
}

/// IDs of files named `<prefix><id><suffix>`, sorted oldest first.
fn ids(dir: &Path, prefix: &str, suffix: &str) -> Vec<String> {
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut ids: Vec<String> = entries
        .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
        .filter_map(|name| Some(name.strip_prefix(prefix)?.strip_suffix(suffix)?.to_string()))
        .collect();
    ids.sort();
    ids
}

pub fn start(dir: &Path, id: &str) -> io::Result<Session> {
    fs::create_dir_all(dir)?;
    let marker = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(marker_path(dir, id))?;
    marker.try_lock().map_err(io::Error::from)?;
    Ok(Session {
        id: id.to_string(),
        log: log_path(dir, id),
        dir: dir.to_path_buf(),
        _marker: marker,
    })
}

impl Session {
    /// A clean exit: the marker goes, and older clean logs are pruned.
    pub fn finish(self) {
        let _ = fs::remove_file(marker_path(&self.dir, &self.id));
        let markers = ids(&self.dir, "session-", ".marker");
        let clean: Vec<String> = ids(&self.dir, "session-", ".jsonl")
            .into_iter()
            .filter(|id| !markers.contains(id))
            .collect();
        for id in clean.iter().rev().skip(KEEP_LOGS) {
            let _ = fs::remove_file(log_path(&self.dir, id));
        }
    }
}

/// Turns every other session whose marker is no longer locked into a report.
pub fn collect(dir: &Path, own: &str, os: &str) -> Vec<PathBuf> {
    let mut reports = Vec::new();
    for id in ids(dir, "session-", ".marker") {
        if id == own {
            continue;
        }
        let Ok(marker) = OpenOptions::new().write(true).open(marker_path(dir, &id)) else {
            continue;
        };
        match marker.try_lock() {
            Ok(()) => {}
            Err(TryLockError::WouldBlock) | Err(TryLockError::Error(_)) => continue,
        }
        let log = fs::read_to_string(log_path(dir, &id)).ok();
        let path = report_path(dir, &id);
        if fs::write(&path, build_report(&id, log.as_deref(), os)).is_err() {
            continue;
        }
        let _ = fs::remove_file(log_path(dir, &id));
        let _ = fs::remove_file(marker_path(dir, &id));
        reports.push(path);
    }
    let all = ids(dir, "crash-", ".txt");
    for id in all.iter().rev().skip(KEEP_REPORTS) {
        let _ = fs::remove_file(report_path(dir, id));
        let _ = fs::remove_file(seen_path(dir, id));
    }
    reports.retain(|path| path.exists());
    reports
}

/// `20261117T121130.000Z-2` → `2026-11-17 12:11:30 UTC`.
fn started(id: &str) -> String {
    let digits: Vec<char> = id.chars().collect();
    if digits.len() < 15 || digits[8] != 'T' {
        return id.to_string();
    }
    let part = |from: usize, to: usize| digits[from..to].iter().collect::<String>();
    format!(
        "{}-{}-{} {}:{}:{} UTC",
        part(0, 4),
        part(4, 6),
        part(6, 8),
        part(9, 11),
        part(11, 13),
        part(13, 15)
    )
}

fn summary_line(record: &Map<String, Value>) -> String {
    let at = record.get("at").and_then(Value::as_str).unwrap_or("");
    let clock = at.get(11..23).unwrap_or(at);
    let elapsed = record
        .get("elapsed_ms")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let text = |key: &str| record.get(key).and_then(Value::as_str).unwrap_or("?");
    let mut line = format!(
        "{clock} +{}.{:03}s {} {}",
        elapsed / 1000,
        elapsed % 1000,
        text("source"),
        text("event")
    );
    for (key, value) in record {
        if BASE_FIELDS.contains(&key.as_str()) {
            continue;
        }
        let value = match value {
            Value::String(text) => text.clone(),
            other => other.to_string(),
        };
        line.push_str(&format!(" {key}={value}"));
    }
    line
}

pub fn build_report(id: &str, log: Option<&str>, os: &str) -> String {
    let since = started(id);
    let mut report = format!(
        "Feud Hall crash report\n\
         Session started: {since}\n\
         The session did not exit cleanly (a crash, a forced quit, or a power loss).\n"
    );
    let text = log.unwrap_or("");
    let mut records = Vec::new();
    let mut unreadable = 0;
    for line in text.lines().filter(|line| !line.trim().is_empty()) {
        match serde_json::from_str::<Value>(line) {
            Ok(Value::Object(record)) => records.push(record),
            _ => unreadable += 1,
        }
    }
    if let Some(last) = records.last().and_then(|record| record.get("at")) {
        report.push_str(&format!("Last record: {}\n", last.as_str().unwrap_or("?")));
    }
    if let Some(environment) = records
        .iter()
        .find(|record| record.get("event").and_then(Value::as_str) == Some("session_started"))
    {
        report.push_str("\nEnvironment:\n");
        for (key, value) in environment {
            if !BASE_FIELDS.contains(&key.as_str()) {
                report.push_str(&format!("  {key}: {value}\n"));
            }
        }
    }
    if records.is_empty() {
        report.push_str("\nno breadcrumbs were recorded\n");
    } else {
        let skip = records.len().saturating_sub(SUMMARY_RECORDS);
        report.push_str(&format!("\nLast {} events:\n", records.len() - skip));
        for record in &records[skip..] {
            report.push_str(&format!("  {}\n", summary_line(record)));
        }
    }
    if unreadable > 0 {
        report.push_str(&format!("unreadable lines: {unreadable}\n"));
    }
    report.push_str("\nFinding the stack:\n");
    if os == "macos" {
        report.push_str(
            "  Look in ~/Library/Logs/DiagnosticReports for a feud-hall-* file\n  \
             from around the last record's time.\n",
        );
    } else {
        report.push_str(&format!(
            "  coredumpctl list feud-hall --since \"{since}\"\n  \
             flatpak install --user flathub org.gnome.Sdk//50 org.gnome.Sdk.Debug//50 org.gnome.Platform.Debug//50\n  \
             flatpak-coredumpctl -m <PID from that list> io.github.adsouza.FeudHall\n  \
             Then, at the (gdb) prompt: bt full, then thread apply all bt\n"
        ));
    }
    report.push_str("\n--- breadcrumbs (JSON Lines) ---\n");
    report.push_str(text);
    report
}

#[derive(Serialize, Debug)]
pub struct ReportSummary {
    pub id: String,
    pub path: String,
}

/// Reports not yet acknowledged, newest first.
pub fn pending(dir: &Path) -> Vec<ReportSummary> {
    ids(dir, "crash-", ".txt")
        .into_iter()
        .rev()
        .filter(|id| !seen_path(dir, id).exists())
        .map(|id| ReportSummary {
            path: report_path(dir, &id).display().to_string(),
            id,
        })
        .collect()
}

pub fn acknowledge(dir: &Path) {
    for report in pending(dir) {
        let _ = fs::write(seen_path(dir, &report.id), "");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn scratch(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("feud-hall-reports-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    const LOG: &str = concat!(
        r#"{"v":1,"at":"2026-11-17T12:11:30.000Z","elapsed_ms":0,"source":"native","event":"session_started","session_type":"wayland"}"#,
        "\n",
        r#"{"v":1,"at":"2026-11-17T12:11:50.500Z","elapsed_ms":20500,"source":"native","event":"window_focus","focused":false}"#,
        "\n",
        r#"{"v":1,"at":"2026-11-17T12:11:55.250Z","elapsed_ms":25250,"source":"native","event":"selection_owner_changed","selection":"primary","reason":"new_owner"}"#,
        "\n",
    );

    fn dead_session(dir: &Path, id: &str, log: Option<&str>) {
        fs::write(dir.join(format!("session-{id}.marker")), "").unwrap();
        if let Some(log) = log {
            fs::write(dir.join(format!("session-{id}.jsonl")), log).unwrap();
        }
    }

    #[test]
    fn session_id_sorts_by_start() {
        let id = session_id(time::macros::datetime!(2026-11-17 12:11:55.123 UTC), 2);
        assert_eq!(id, "20261117T121155.123Z-2");
    }

    #[test]
    fn dead_session_becomes_report() {
        let dir = scratch("dead");
        dead_session(&dir, "20261117T121130.000Z-2", Some(LOG));
        let reports = collect(&dir, "20261117T130000.000Z-2", "linux");
        assert_eq!(reports, vec![dir.join("crash-20261117T121130.000Z-2.txt")]);
        let report = fs::read_to_string(&reports[0]).unwrap();
        assert!(report.contains("coredumpctl list feud-hall --since \"2026-11-17 12:11:30 UTC\""));
        assert!(report.contains("flatpak-coredumpctl -m"));
        assert!(report.contains("selection_owner_changed"));
        assert!(report.contains("selection=primary"));
        assert!(report.contains("2026-11-17T12:11:55.250Z"));
        assert!(report.contains(LOG.lines().last().unwrap()));
        assert!(!dir.join("session-20261117T121130.000Z-2.marker").exists());
        assert!(!dir.join("session-20261117T121130.000Z-2.jsonl").exists());
    }

    #[test]
    fn running_session_is_left_alone() {
        let dir = scratch("running");
        let running = start(&dir, "20261117T121130.000Z-2").unwrap();
        assert!(collect(&dir, "20261117T130000.000Z-2", "linux").is_empty());
        assert!(dir.join("session-20261117T121130.000Z-2.marker").exists());
        drop(running);
    }

    #[test]
    fn partial_line_and_missing_log_still_report() {
        let dir = scratch("partial");
        let partial = format!("{LOG}{}", r#"{"v":1,"at":"2026-"#);
        dead_session(&dir, "20261117T100000.000Z-2", Some(&partial));
        dead_session(&dir, "20261117T110000.000Z-2", None);
        collect(&dir, "20261117T130000.000Z-2", "linux");
        let partial = fs::read_to_string(dir.join("crash-20261117T100000.000Z-2.txt")).unwrap();
        assert!(partial.contains("unreadable lines: 1"));
        let missing = fs::read_to_string(dir.join("crash-20261117T110000.000Z-2.txt")).unwrap();
        assert!(missing.contains("no breadcrumbs were recorded"));
    }

    #[test]
    fn finish_removes_marker() {
        let dir = scratch("finish");
        start(&dir, "20261117T121130.000Z-2").unwrap().finish();
        assert!(collect(&dir, "20261117T130000.000Z-2", "linux").is_empty());
        assert!(!dir.join("session-20261117T121130.000Z-2.marker").exists());
    }

    #[test]
    fn pending_and_acknowledge() {
        let dir = scratch("pending");
        dead_session(&dir, "20261117T100000.000Z-2", Some(LOG));
        dead_session(&dir, "20261117T110000.000Z-2", Some(LOG));
        collect(&dir, "20261117T130000.000Z-2", "macos");
        let listed = pending(&dir);
        assert_eq!(listed.len(), 2);
        assert_eq!(listed[0].id, "20261117T110000.000Z-2");
        assert!(listed[0].path.ends_with("crash-20261117T110000.000Z-2.txt"));
        let report = fs::read_to_string(&listed[0].path).unwrap();
        assert!(report.contains("~/Library/Logs/DiagnosticReports"));
        acknowledge(&dir);
        assert!(pending(&dir).is_empty());
    }

    #[test]
    fn prune_keeps_five_reports() {
        let dir = scratch("prune");
        for hour in 10..17 {
            dead_session(&dir, &format!("20261117T{hour}0000.000Z-2"), Some(LOG));
        }
        collect(&dir, "20261117T200000.000Z-2", "linux");
        let mut kept: Vec<String> = fs::read_dir(&dir)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .filter(|name| name.starts_with("crash-"))
            .collect();
        kept.sort();
        assert_eq!(kept.len(), 5);
        assert_eq!(kept[0], "crash-20261117T120000.000Z-2.txt");
    }

    #[test]
    fn clean_logs_are_pruned_to_five() {
        let dir = scratch("clean");
        for hour in 10..17 {
            let id = format!("20261117T{hour}0000.000Z-2");
            fs::write(dir.join(format!("session-{id}.jsonl")), LOG).unwrap();
        }
        start(&dir, "20261117T200000.000Z-2").unwrap().finish();
        let logs = fs::read_dir(&dir)
            .unwrap()
            .filter(|entry| {
                entry
                    .as_ref()
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .ends_with(".jsonl")
            })
            .count();
        assert_eq!(logs, 5);
    }

    #[test]
    fn unreadable_dir_gives_empty_pending() {
        let file = scratch("unreadable").join("not-a-folder");
        fs::write(&file, "file").unwrap();
        assert!(pending(&file).is_empty());
        assert!(collect(&file, "x", "linux").is_empty());
        assert!(start(&file, "x").is_err());
    }
}
