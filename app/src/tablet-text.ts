/**
 * Fit complete words into a bounded canvas label. Currency amounts stay atomic;
 * Japanese uses language-aware break opportunities instead of needing spaces.
 */
export function layoutTabletText(
  value: string,
  width: number,
  size: number,
  maxLines: number,
  measure: (text: string, size: number) => number,
): { size: number; lines: string[] } {
  const japaneseWords = new Intl.Segmenter("ja", { granularity: "word" });
  const tokens = (value.match(/\s+|\S+/gu) ?? []).flatMap((token) =>
    /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]/u.test(token)
      ? Array.from(japaneseWords.segment(token), (part) => part.segment)
      : [token],
  );
  for (let fitted = size; fitted >= 1; fitted--) {
    const lines = [];
    let line = "";
    let space = "";
    for (const token of tokens) {
      if (/^\s+$/u.test(token)) {
        space = line ? " " : "";
        continue;
      }
      const candidate = line + space + token;
      if (line && measure(candidate, fitted) > width) {
        lines.push(line);
        line = token;
      } else line = candidate;
      space = "";
    }
    if (line) lines.push(line);
    if (
      lines.length <= maxLines &&
      lines.every((text) => measure(text, fitted) <= width)
    )
      return { size: fitted, lines };
  }
  return { size: 1, lines: [value] };
}

/** Keep long notices readable across tablet rows without cutting words in half. */
export function splitTabletMessage(value: string): string[] {
  const words = new Intl.Segmenter("ja", { granularity: "word" });
  const tokens = (value.match(/\s+|\S+/gu) ?? []).flatMap((token) =>
    /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]/u.test(token)
      ? Array.from(words.segment(token), (part) => part.segment)
      : [token],
  );
  const limit = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]/u.test(
    value,
  )
    ? 32
    : 80;
  const rows: string[] = [];
  let line = "",
    space = "";
  for (const token of tokens) {
    if (/^\s+$/u.test(token)) {
      space = line ? " " : "";
      continue;
    }
    const candidate = line + space + token;
    if (line && Array.from(candidate).length > limit) {
      rows.push(line);
      line = token;
    } else line = candidate;
    space = "";
  }
  if (line) rows.push(line);
  return rows;
}
