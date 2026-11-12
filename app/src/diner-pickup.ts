import type { DiningHistory, Profile } from "./api";

export type PersonalTray = { id: string; stall: string };

/** Private committed service facts only; counter/preparation animations cannot create pickups. */
export function servedTrays(
  profile: Pick<Profile, "account" | "visit"> | null,
  history: DiningHistory | null,
  now: number,
): PersonalTray[] {
  if (!profile) return [];
  const result = new Map<string, PersonalTray>();
  const add = (visit: string, stall: string, course: string) => {
    const id = `${profile.account.id}:${visit}:${course}`;
    result.set(id, { id, stall });
  };
  const visit = profile.visit;
  if (visit?.tray_status === "served") add(visit.id, visit.stall, "main");
  if (visit?.stage === "served" && visit.dessert === "accepted")
    add(visit.id, visit.stall, "dessert");
  for (const receipt of history?.receipts ?? []) {
    if (now - receipt.at > 720_000 || receipt.at > now) continue;
    for (const kind of ["main", "dessert"])
      if (
        receipt.courses.some(
          (course) => course.kind === kind && course.outcome === "served",
        )
      )
        add(receipt.visit_id, receipt.stall_id, kind);
  }
  return [...result.values()].slice(0, 40);
}
