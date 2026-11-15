import * as T from "three";
import { layoutTabletText } from "./tablet-text";

export type TabletAction =
  | { kind: "main" | "drink" | "diet"; id: string }
  | { kind: "confirm"; token: string }
  | {
      kind:
        | "open"
        | "close"
        | "menu"
        | "diets"
        | "drinks"
        | "review"
        | "dessert"
        | "skip"
        | "allowance"
        | "guest"
        | "cancel"
        | "retry"
        | "reload"
        | "visit";
    };
export type TabletRow = {
  text: string;
  error?: boolean;
  detail?: string;
  action?: TabletAction;
  disabled?: boolean;
  selected?: boolean;
};
export type TabletView = {
  standby?: boolean;
  stall: string;
  title: string;
  subtitle: string;
  notice: string;
  noticeError?: boolean;
  rows: TabletRow[];
  previous: string;
  next: string;
  close: string;
};

const WIDTH = 720;
const HEIGHT = 1080;
const TOP = 180;
const ROW_HEIGHT = 120;
const PER_PAGE = 6;
const FOOTER = 930;

type Target = {
  x: number;
  y: number;
  width: number;
  height: number;
  action?: TabletAction;
  page?: number;
};

/** A physical screen texture and UV hit map; economic actions remain in App. */
export function createTabletScreen(redraw: () => void) {
  const canvas = document.createElement("canvas");
  canvas.width = WIDTH;
  canvas.height = HEIGHT;
  const context = canvas.getContext("2d")!;
  const texture = new T.CanvasTexture(canvas);
  texture.colorSpace = T.SRGBColorSpace;
  texture.minFilter = T.LinearFilter;
  const material = new T.MeshBasicMaterial({ map: texture, toneMapped: false });
  let view: TabletView | null = null;
  let fingerprint = "";
  let page = 0;
  let focused = -1;
  let targets: Target[] = [];
  let disposed = false;

  function text(
    value: string,
    x: number,
    y: number,
    width: number,
    size = 36,
    maxLines = 2,
  ) {
    const layout = layoutTabletText(
      value,
      width,
      size,
      maxLines,
      (label, fontSize) => {
        context.font = `400 ${fontSize}px "Noto Sans JP", system-ui, sans-serif`;
        return context.measureText(label).width;
      },
    );
    context.font = `400 ${layout.size}px "Noto Sans JP", system-ui, sans-serif`;
    layout.lines.forEach((line, index) =>
      context.fillText(line, x, y + index * (layout.size + 5)),
    );
  }

  function paint() {
    if (!view || disposed) return;
    context.fillStyle = "#101724";
    context.fillRect(0, 0, WIDTH, HEIGHT);
    context.textBaseline = "top";
    context.fillStyle = "#ffcd6d";
    text(view.title, 30, 22, 660, 42, 1);
    context.fillStyle = "#e8efef";
    text(view.subtitle, 30, 76, 660, 32, 1);
    context.fillStyle = view.noticeError ? "#ff8f93" : "#9be5d0";
    text(view.notice, 30, 120, 660, 28, 2);
    const rows = view.rows.slice(page * PER_PAGE, (page + 1) * PER_PAGE);
    targets = [];
    rows.forEach((row, index) => {
      const y = TOP + index * ROW_HEIGHT;
      const target: Target = {
        x: 20,
        y,
        width: 680,
        height: ROW_HEIGHT - 8,
        action: row.disabled ? undefined : row.action,
      };
      context.fillStyle = row.error
        ? "#351e29"
        : row.selected
          ? "#234941"
          : row.action
            ? "#253145"
            : "#172232";
      context.fillRect(target.x, target.y, target.width, target.height);
      if (target.action) {
        targets.push(target);
        if (
          (target.action || target.page !== undefined) &&
          targets.length - 1 === focused
        ) {
          context.strokeStyle = "#ffcd6d";
          context.lineWidth = 5;
          context.strokeRect(
            target.x + 3,
            target.y + 3,
            target.width - 6,
            target.height - 6,
          );
        }
      }
      context.fillStyle = row.error
        ? "#ff8f93"
        : row.disabled
          ? "#9ca9b9"
          : "#ffffff";
      text(row.text, 36, y + 12, 648, 36, row.detail ? 1 : 2);
      if (row.detail) {
        context.fillStyle = "#b9d4d7";
        text(row.detail, 36, y + 60, 648, 27, 1);
      }
    });
    const count = Math.max(1, Math.ceil(view.rows.length / PER_PAGE));
    const footer = [
      { text: view.previous, page: page > 0 ? page - 1 : undefined },
      { text: view.close, action: { kind: "close" } as TabletAction },
      { text: view.next, page: page + 1 < count ? page + 1 : undefined },
    ];
    if (!view.standby)
      footer.forEach((item, index) => {
        const x = 20 + index * 228;
        const target: Target = {
          x,
          y: FOOTER,
          width: 220,
          height: 125,
          ...item,
        };
        if (target.action || target.page !== undefined) targets.push(target);
        context.fillStyle =
          target.action || target.page !== undefined ? "#394658" : "#1a2533";
        context.fillRect(x, FOOTER, 220, 125);
        if (
          (target.action || target.page !== undefined) &&
          targets.length - 1 === focused
        ) {
          context.strokeStyle = "#ffcd6d";
          context.lineWidth = 5;
          context.strokeRect(x + 3, FOOTER + 3, 214, 119);
        }
        context.fillStyle = "#f6ead2";
        text(item.text, x + 14, FOOTER + 18, 192, 30, 2);
      });
    if (!view.standby) {
      context.fillStyle = "#b9d4d7";
      text(`${page + 1} / ${count}`, 315, 902, 120, 22, 1);
    }
    texture.needsUpdate = true;
  }

  function activate(target: Target | undefined): TabletAction | undefined {
    if (target?.page !== undefined) {
      page = target.page;
      focused = -1;
      paint();
      redraw();
    }
    return target?.action;
  }

  return {
    material,
    update(next: TabletView) {
      const key = JSON.stringify(next);
      if (key === fingerprint) return;
      const errorIndex = next.rows.findIndex((row) => row.error);
      const errors = (rows: TabletRow[]) =>
        rows
          .filter((row) => row.error)
          .map((row) => row.text)
          .join("\n");
      const newError =
        errorIndex >= 0 && errors(next.rows) !== errors(view?.rows ?? []);
      if (
        next.stall !== view?.stall ||
        next.subtitle !== view?.subtitle ||
        newError
      ) {
        page = errorIndex >= 0 ? Math.floor(errorIndex / PER_PAGE) : 0;
        focused = -1;
      }
      view = next;
      fingerprint = key;
      page = Math.min(
        page,
        Math.max(0, Math.ceil(next.rows.length / PER_PAGE) - 1),
      );
      paint();
      const letters =
        next.title +
        next.subtitle +
        next.notice +
        next.rows.map((row) => row.text + (row.detail ?? "")).join("");
      if (
        /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]/u.test(letters)
      )
        void document.fonts
          .load('400 36px "Noto Sans JP"', letters)
          .then(() => {
            if (!disposed && fingerprint === key) {
              paint();
              redraw();
            }
          })
          .catch(() => {});
    },
    hit(u: number, v: number) {
      return activate(
        targets.find(
          (target) =>
            u * WIDTH >= target.x &&
            u * WIDTH <= target.x + target.width &&
            v * HEIGHT >= target.y &&
            v * HEIGHT <= target.y + target.height,
        ),
      );
    },
    key(key: string, backwards: boolean) {
      if (key === "ArrowLeft" || key === "ArrowRight") {
        page = Math.max(
          0,
          Math.min(
            Math.ceil((view?.rows.length ?? 0) / PER_PAGE) - 1,
            page + (key === "ArrowLeft" ? -1 : 1),
          ),
        );
        focused = -1;
        paint();
        redraw();
        return undefined;
      }
      if (key === "Home" || key === "End") {
        page =
          key === "Home"
            ? 0
            : Math.max(0, Math.ceil((view?.rows.length ?? 0) / PER_PAGE) - 1);
        focused = 0;
        paint();
        redraw();
        return undefined;
      }
      if (key === "Escape") return { kind: "close" } as TabletAction;
      if (key === "Enter" || key === " ") return activate(targets[focused]);
      if (key === "ArrowDown" || key === "ArrowUp" || key === "Tab") {
        const direction = key === "ArrowUp" || backwards ? -1 : 1;
        focused =
          focused < 0
            ? direction > 0
              ? 0
              : targets.length - 1
            : (focused + direction + targets.length) % targets.length;
        paint();
        redraw();
      }
      return undefined;
    },
    dispose() {
      disposed = true;
      texture.dispose();
      material.dispose();
    },
  };
}
