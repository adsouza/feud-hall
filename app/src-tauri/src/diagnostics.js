// Installed in the local main webview before the shared application starts.
// Sends crash breadcrumbs to the native log: the kind of event and bounded
// numbers only. Never selected, copied, or typed text.
(() => {
  const internals = window.__TAURI_INTERNALS__;
  if (!internals) return;

  // A failed report is dropped silently. Its rejection must not reach the
  // unhandledrejection listener below, or one failure would report itself
  // forever.
  function send(crumb) {
    try {
      Promise.resolve(
        internals.invoke("diagnostic_breadcrumb", { crumb }),
      ).catch(() => {});
    } catch {
      // Diagnostics must never break the page.
    }
  }

  const text = (value) => String(value ?? "").slice(0, 300);

  document.addEventListener("visibilitychange", () =>
    send({
      kind: "visibility",
      visible: document.visibilityState === "visible",
    }),
  );
  window.addEventListener("focus", () =>
    send({ kind: "focus", focused: true }),
  );
  window.addEventListener("blur", () =>
    send({ kind: "focus", focused: false }),
  );
  document.addEventListener("copy", () => send({ kind: "copy" }), true);
  document.addEventListener("cut", () => send({ kind: "cut" }), true);

  // Selecting text makes the webview the owner of the primary selection on
  // Linux. Report when a selection starts, with its length only.
  let selected = false;
  document.addEventListener("selectionchange", () => {
    let length = 0;
    try {
      const field = document.activeElement;
      if (
        field instanceof HTMLInputElement ||
        field instanceof HTMLTextAreaElement
      )
        length = Math.abs(
          (field.selectionEnd ?? 0) - (field.selectionStart ?? 0),
        );
      else length = window.getSelection()?.toString().length ?? 0;
    } catch {
      return;
    }
    if (length === 0) selected = false;
    else if (!selected) {
      selected = true;
      send({ kind: "selection", length: Math.min(length, 4294967295) });
    }
  });

  document.addEventListener(
    "webglcontextlost",
    () => send({ kind: "webgl_lost" }),
    true,
  );
  document.addEventListener(
    "webglcontextrestored",
    () => send({ kind: "webgl_restored" }),
    true,
  );

  window.addEventListener("error", (event) => {
    if (!(event instanceof ErrorEvent)) return;
    send({
      kind: "error",
      message: text(event.message),
      file: text(event.filename),
      line:
        Number.isInteger(event.lineno) && event.lineno >= 0 ? event.lineno : 0,
    });
  });
  window.addEventListener("unhandledrejection", (event) => {
    const reason = event.reason;
    send({
      kind: "rejection",
      message: text(reason instanceof Error ? reason.message : reason),
    });
  });

  function reportGpu() {
    try {
      const gl = document.createElement("canvas").getContext("webgl");
      const info = gl?.getExtension("WEBGL_debug_renderer_info");
      if (!gl || !info) return;
      send({
        kind: "gpu",
        vendor: text(gl.getParameter(info.UNMASKED_VENDOR_WEBGL)).slice(0, 200),
        renderer: text(gl.getParameter(info.UNMASKED_RENDERER_WEBGL)).slice(
          0,
          200,
        ),
      });
      gl.getExtension("WEBGL_lose_context")?.loseContext();
    } catch {
      // No WebGL: the hall's HTML view covers it, and nothing is reported.
    }
  }
  if ("requestIdleCallback" in window)
    window.requestIdleCallback(reportGpu, { timeout: 5000 });
  else setTimeout(reportGpu, 1000);
})();
