// Installed in the local main webview before the shared application starts.
// Keep this state separate from device credentials and the hall camera.
(() => {
  const key = "feud-hall.ui-zoom.v1";
  const mac = "__FEUD_OS__" === "macos";
  const minimum = 20;
  const maximum = 1000;
  let desired = 100;
  let applied = null;
  let running = false;
  let warned = false;

  try {
    const saved = window.localStorage.getItem(key);
    const percent = Number(saved);
    if (
      saved !== null &&
      Number.isInteger(percent) &&
      percent >= minimum &&
      percent <= maximum
    )
      desired = percent;
  } catch {
    // An unavailable or corrupt preference must not block the game.
  }

  async function apply() {
    if (running) return;
    running = true;
    try {
      while (desired !== applied) {
        const next = desired;
        await window.__TAURI_INTERNALS__.invoke(
          "plugin:webview|set_webview_zoom",
          { value: next / 100 },
        );
        applied = next;
        try {
          window.localStorage.setItem(key, String(next));
        } catch {
          if (!warned) console.warn("Could not save the UI zoom preference.");
          warned = true;
        }
      }
    } catch {
      desired = applied ?? 100;
      console.warn("Could not apply UI zoom.");
    } finally {
      running = false;
    }
  }

  function change(percent) {
    desired = Math.min(maximum, Math.max(minimum, percent));
    void apply();
  }

  window.addEventListener(
    "keydown",
    (event) => {
      if (
        event.isComposing ||
        event.altKey ||
        !(mac ? event.metaKey : event.ctrlKey)
      )
        return;
      let next;
      if (event.key === "=" || event.key === "+") next = desired + 20;
      else if (event.key === "-") next = desired - 20;
      else if (event.key === "0") next = 100;
      else return;
      event.preventDefault();
      event.stopPropagation();
      change(next);
    },
    { capture: true },
  );

  // Capture modified wheel input before OrbitControls can zoom the hall camera.
  window.addEventListener(
    "wheel",
    (event) => {
      if (
        !event.ctrlKey ||
        !Number.isFinite(event.deltaY) ||
        event.deltaY === 0
      )
        return;
      event.preventDefault();
      event.stopPropagation();
      change(desired + (event.deltaY < 0 ? 20 : -20));
    },
    { capture: true, passive: false },
  );

  void apply();
})();
