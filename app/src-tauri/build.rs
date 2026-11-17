fn main() {
    println!("cargo:rerun-if-env-changed=FEUD_HALL_NATIVE_ORIGIN");
    let manifest = tauri_build::AppManifest::new().commands(&[
        "hall_request",
        "diagnostic_breadcrumb",
        "crash_reports",
        "acknowledge_crash_reports",
        "reveal_crash_report",
    ]);
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(manifest))
        .expect("build the Feud Hall Tauri shell");
}
