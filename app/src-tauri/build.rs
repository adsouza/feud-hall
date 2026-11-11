fn main() {
    println!("cargo:rerun-if-env-changed=FEUD_HALL_NATIVE_ORIGIN");
    let manifest = tauri_build::AppManifest::new().commands(&["hall_request"]);
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(manifest))
        .expect("build the Feud Hall Tauri shell");
}
