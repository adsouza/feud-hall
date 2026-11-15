// The market's drafts for this session: kept outside the panel so they
// survive leaving the Supply section and live view updates. Nothing here is
// stored across a reload.
import { emptyCart, type Cart } from "./market-cart";
import type { VendorId } from "./market-goods";

/** What became of one delivery through the app's submitting path. */
export type Delivery = {
  outcome: "accepted" | "refused" | "uncertain" | "skipped";
  commandId: string | null;
  reason: string | null;
};

/** A purchase request this device sent. */
export type SentLine = {
  commandId: string;
  product: string;
  /** The send's outcome is unknown; it is resolved by this command ID only. */
  uncertain: boolean;
  /** When it stopped being pending (Date.now()), or null. */
  leftAt: number | null;
};

export const market = $state<{
  restaurant: string;
  cart: Cart;
  vendor: VendorId | null;
  selected: string;
  /** Limit text being typed, by product, while it differs from the line's limit. */
  limitText: Record<string, string>;
  /** The server's reason a line's last send was refused, by product. */
  refused: Record<string, string>;
  sent: SentLine[];
}>({
  restaurant: "",
  cart: emptyCart,
  vendor: null,
  selected: "",
  limitText: {},
  refused: {},
  sent: [],
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
  if (delivery.outcome === "accepted") line.uncertain = false;
  else if (delivery.outcome === "refused")
    market.sent = market.sent.filter((s) => s !== line);
}
