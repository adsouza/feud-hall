// The market's drafts for this session: kept outside the panel so they
// survive leaving the Supply section and live view updates. Nothing here is
// stored across a reload: "On its way" is rebuilt from the server's view.
import {
  emptyCart,
  emptyWayMemory,
  recordSend,
  type Cart,
  type SessionSend,
  type WayMemory,
} from "./market-cart";
import type { VendorId } from "./market-goods";

/** What became of one delivery through the app's submitting path. */
export type Delivery = {
  outcome: "accepted" | "refused" | "uncertain" | "skipped";
  commandId: string | null;
  reason: string | null;
  /** The newest view request issued when the result was known (see `views`). */
  viewStamp: number;
};

/**
 * Stamps on the app's view requests: `requested` counts requests issued,
 * `shown` is the request that produced the view on screen. A view whose
 * stamp is above a command's acceptance stamp was requested after the
 * command committed, so it reflects it.
 */
export const views = $state({ requested: 0, shown: 0 });
export function viewRequested(): number {
  return ++views.requested;
}
export function viewShown(stamp: number) {
  if (stamp > views.shown) views.shown = stamp;
}

export const market = $state<{
  restaurant: string;
  cart: Cart;
  vendor: VendorId | null;
  selected: string;
  /** Limit text being typed, by product, while it differs from the line's limit. */
  limitText: Record<string, string>;
  /** The server's reason a line's last send was refused, by product. */
  refused: Record<string, string>;
  /** Purchase requests this session sent, oldest first. */
  sent: SessionSend[];
  /** What "On its way" remembers between views. */
  way: WayMemory;
}>({
  restaurant: "",
  cart: emptyCart,
  vendor: null,
  selected: "",
  limitText: {},
  refused: {},
  sent: [],
  way: emptyWayMemory,
});

/** Starts over when another restaurant's view arrives (a new owner on this device). */
export function forRestaurant(id: string) {
  if (market.restaurant === id) return;
  market.restaurant = id;
  market.cart = emptyCart;
  market.vendor = null;
  market.selected = "";
  market.limitText = {};
  market.refused = {};
  market.sent = [];
  market.way = emptyWayMemory;
}

/**
 * The app finished a delivery: an uncertain send named by it is resolved.
 * Accepted, it is tracked like any other; refused, it leaves "On its way"
 * (the app's banner shows the refusal). Still uncertain, nothing changes.
 */
export function resolveSent(delivery: Delivery) {
  if (!delivery.commandId) return;
  const line = market.sent.find(
    (s) => s.uncertain && s.commandId === delivery.commandId,
  );
  if (!line) return;
  if (delivery.outcome === "accepted")
    market.sent = recordSend(market.sent, {
      commandId: line.commandId,
      product: line.product,
      outcome: "accepted",
      stamp: delivery.viewStamp,
      now: Date.now(),
    });
  else if (delivery.outcome === "refused")
    market.sent = market.sent.filter((s) => s !== line);
}

let webglProbe: boolean | undefined;
/**
 * Whether this browser can give the market a WebGL context, probed once per
 * page with a throwaway canvas whose context is released at once. The scene
 * itself is created only when it comes on screen, so without this the list
 * would not say it is the market until the picture was scrolled to.
 */
export function webglAvailable(): boolean {
  if (webglProbe !== undefined) return webglProbe;
  try {
    const canvas = document.createElement("canvas");
    const gl = (canvas.getContext("webgl2") ?? canvas.getContext("webgl")) as
      WebGLRenderingContext | WebGL2RenderingContext | null;
    webglProbe = gl !== null;
    gl?.getExtension("WEBGL_lose_context")?.loseContext();
  } catch {
    webglProbe = false;
  }
  return webglProbe;
}
