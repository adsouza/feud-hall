// The hall serves the web client's page at "/", and the build content-hashes
// the entry module's name, so a different name there means the hall now serves
// different client code than this tab is running.
export const CLIENT_CHECK_MS = 10 * 60 * 1000;

export function entryScript(doc: Document): string | null {
  return (
    doc
      .querySelector<HTMLScriptElement>('script[type="module"][src]')
      ?.getAttribute("src") ?? null
  );
}

// A failed or unexpected answer is not evidence of a newer client: the next
// check tries again.
export async function newerClientServed(): Promise<boolean> {
  const running = entryScript(document);
  if (!running) return false;
  try {
    const response = await fetch("/", { cache: "no-store" });
    if (!response.ok) return false;
    const served = entryScript(
      new DOMParser().parseFromString(await response.text(), "text/html"),
    );
    return served !== null && served !== running;
  } catch {
    return false;
  }
}
