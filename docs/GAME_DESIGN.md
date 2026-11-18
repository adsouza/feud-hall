# Feud Hall Game Design

Version 0.34 · Design baseline for implementation planning

Feud Hall is a restaurant-management simulation with offline single-player and persistent online multiplayer halls. Players compete twice: first for wholesale ingredients, then for diners. They choose cuisines and menus, set prices, hire and schedule staff, improve equipment, and expand into additional stalls. Staff perform kitchen work automatically. A successful business balances demand, quality, capacity, and costs while rivals make their own decisions in the same economy.

The first release supports local single-player halls and one public multiplayer hall, each with space for 150 physical stalls, twenty-five cuisines, and NPC competitors. Visitors can play as customers or take optional short helper shifts without an owner invitation. The multiplayer hall continues running while players are away; a single-player hall pauses while the game is closed. Both modes have a mandatory daily cleaning closure from 03:00 to 05:00 game time (five real minutes). In multiplayer, restaurants close by default when their owners leave; players can explicitly enable unattended operation with automation and safety limits.

Navigation: [play modes](#play-modes), [experience and ownership](#2-player-experience-and-design-pillars), [account invitations](#invitation-tree-and-account-access), [restaurant licenses](#restaurant-licenses-and-applications), [time and absence](#5-time-opening-hours-and-owner-absence), [customers and supplies](#7-competing-for-customers), [cuisines and staffing](#9-cuisines-recipes-and-equipment), [finance and progression](#11-finance-and-viable-businesses), [NPCs](#14-npc-competition-and-population-changes), [presentation](#15-interface-3d-presentation-and-audio), [technical design](#16-authoritative-simulation-and-domain-boundaries), [acceptance](#19-observability-balance-and-acceptance), [scope and tuning](#20-first-release-scope-and-implementation-order).

## 1. Status and design authority

This document combines the original design discussion with the owner's subsequent clarifications. It defines a coherent proposed game rather than preserving every alternative or code example from that discussion.

The constraints in the following table are **owner-confirmed**. Other rules in this document are **proposed design defaults** intended to make the game concrete and implementable. Numerical prices, rates, thresholds, and durations identified as tuning values are starting hypotheses, not validated balance. Changes to confirmed constraints require a new owner decision; tuning does not.

| Area | Confirmed requirement |
| --- | --- |
| World | Single-player runs locally without a server and pauses while closed. Multiplayer halls run on a server and continue while players are away. |
| Player role | Business management; staff cook automatically. |
| Visitor play | Visitors may play as customers without an owner invitation. Owners may buy from competitors, but cannot purchase from any of their own stalls. |
| Visitor staff | Unlicensed visitors may take optional short staff shifts; licensed restaurant owners cannot work helper shifts at any stall. Owners opt in, NPC restaurants can offer work automatically, permissions are limited to assigned tasks, and automation takes over when a visitor leaves or becomes idle. Virtual wages can be spent on meals. Start with one helper role. |
| Restaurant licenses | Completing a staff shift successfully gives a visitor the opportunity to apply for a restaurant license. Applications appear in a queue that seed/admin players can approve. |
| Capacity | Up to 150 physical stalls per hall, counting every expansion location. This is a stall limit, not a promise of 150 owners with multiple stalls each. |
| Location tradeoffs | Better stall locations attract more foot traffic and cost more in rent. Players see those tradeoffs before choosing a starting stall or expansion. |
| Launch topology | One public multiplayer hall initially, plus separate local single-player saves; private multiplayer halls remain later scope. |
| Sparse population | NPC restaurants provide competition and at least a few operating restaurants initially, approximately three. In multiplayer, once more than twelve humans play simultaneously, NPC restaurants gradually shut down. |
| Goal | Open-ended profitable businesses with optional, nonlinear milestones. |
| Failure | A bankrupt restaurant can be replaced by a brand-new restaurant owned by the same person. Their failed restaurants remain in their history. |
| Cuisines | The twenty-five starter choices are Mughlai/Punjabi, Tamil, Japanese, Sichuan, Cantonese, Mexican, Levantine, Persian, Thai, Berber, Ethiopian, Peruvian, Turkish, Vietnamese, Javanese, Korean, European, Brazilian, Yoruba, Colombian, Haudenosaunee, Diné (Navajo), Lakota, Coast Salish, and Māori. Mughlai/Punjabi and European are each a single starter category. |
| Recipe depth | Each starter cuisine has three savory recipes, one dessert, and one drink, for 125 recipes across twenty-five cuisines. Drinks may optionally accompany the main, and dessert remains optional after a served main. |
| Ingredient substitutes | Most ingredients have a cheaper or more readily available substitute, with a slight reduction in dish quality. |
| Customer dietary needs | Dietary requirements exclude incompatible dishes before customer preferences are scored; vegetarian diners consider only vegetarian food. Support differing requirements, including carbohydrate-restricted choices, through explicit game diet profiles rather than assuming a medical diagnosis determines a diet. |
| Visual direction | A dark background with bright colors. |
| Interaction and onboarding | Owners land on a business overview with live hall context. Teach through ordinary gameplay, contextual explanations, and useful defaults rather than a separate mandatory tutorial. |
| Responsive UI | Core gameplay is usable on smartphone browser screens and takes advantage of larger desktop displays. Screen size changes presentation, not economic rules or permissions. |
| Cuisine selection | Use an equal-area world map with the available cuisine regions highlighted. Eastern Thrace belongs exclusively to the Turkish cuisine region and is excluded from the European cuisine region. |
| UI languages | Ship English and Japanese UI from the first playable release to prove localization works well. |
| Time | One game day lasts one real hour; frequent active management should be useful. |
| Opening hours | The entire hall closes every game day from 03:00 to 05:00 for cleaning: two game hours, or five real minutes while the service is available. No customers are allowed in. Players may review results and plan. Owners choose additional closures outside this mandatory window. |
| Absence | Multiplayer defaults to closing; unattended trading is an explicit option with automation and safety limits. Single-player pauses while closed, regardless of unattended settings. |
| Account invitations | Maintain a durable player-account invitation tree across restaurant failures and restarts. Earn one invitation per 7 cumulative game days of solvent trading. Detailed admission, quota, and expiry rules below are proposed defaults. |
| Platforms | Web, including responsive smartphone browsers, plus Linux and macOS desktop clients. Windows and native iOS/Android apps are outside the initial target. |
| Linux distribution | Hosted CI must generate both Flatpak and Debian `.deb` packages for the Linux client as release artifacts. Both formats are required. |
| Architecture | Shared simulation rules with a local authority for offline single-player and an authoritative Elixir/Phoenix service on Render for multiplayer. Svelte web/native UI connects to the selected mode. Use Domain-Driven Design and Clean Architecture where they provide practical value, retain functional core / imperative shell, and borrow AOP and CQRS techniques where appropriate. |
| Frontend tooling | Use Bun and Oxlint for the TypeScript frontend, with `bun check` for local and hosted type checking instead of a separate `tsc` CLI step; use Oxlint rather than ESLint. |
| Verification | Use property-based testing and mutation testing to discover flaws automatically. |
| Persistence direction | Prefer full gameplay event sourcing from the start, subject to an early capacity, recovery, and compatibility proof. The design adopts this direction; the [ADR](decisions/0001-event-sourcing.md) records the choice and the [architecture document](ARCHITECTURE.md#event-persistence) defines its implementation contracts. |
| Desktop constraints | Tauri desktop packaging was selected in the discussion. No paid Apple Developer account is assumed. |
| Deliverable | Markdown in this repository, suitable for future implementation. |

### How to read the remaining sections

Gameplay rules describe the proposed first release unless explicitly marked as later work. Technical sections specify correctness and architectural boundaries without prescribing every module or reproducing sample implementations. A working implementation must satisfy the acceptance criteria; copying code from the source conversation does not establish compliance.

### Play modes

**Single-player requires no game server or online account.** Start or load a local hall with NPC competition and durable local progress. The player must not need to install/manage Phoenix or PostgreSQL, obtain an online invitation, wait for a licensing reviewer, or contact Render to play. Native and browser delivery must provide a local simulation runtime and saves before claiming this mode is available; installing a PWA alone is insufficient. Current clients still use the networked service; offline execution is planned work.

**Single-player pauses while closed.** Resume from the last committed local state and clock, with no elapsed-wall-time catch-up. Closed time adds no rent, wages, spoilage, cooking, cleaning progress, replenishment, demand, awards, or NPC decisions. Unattended-operation settings do not keep a closed local game running. Preserve pending work and deadlines relative to the paused simulation clocks; recovery may reconcile transient controllers at that unchanged clock without repeating payments. Runtime suspension follows the same no-catch-up rule. During play, the usual 24× hall clock, daily cleaning, finite pools, dietary rules, and automatic kitchen apply.

**Multiplayer uses a shared server.** The public hall keeps running when an individual leaves. Its account/invitation tree, visitor licensing review, attendance/absence policies, security clocks, and server recovery rules below remain in force. One human playing against NPCs in this hall is still multiplayer-mode play and still needs the server.

Local saves and public-hall progress are separate. Offline money, stock, unlocks, work proofs, awards, licenses, and ancestry cannot be imported into the public economy. Local save export/import is local recovery, not multiplayer admission. Proposed local onboarding offers an immediate owner role on a local-only principal when the player chooses to run a restaurant; admission alone still grants no lease, inventory, or extra business capital. Optional local visitor play can use NPC dining/work without requiring another human or a remote review queue. These onboarding details remain proposals; server-free play and pausing while closed are confirmed.

Economic rules below apply in both modes; online accounts, invitations/review, remote security, and player absence policies describe multiplayer unless explicitly stated otherwise.

NPCs remain competing businesses in a single-player save; the multiplayer human-population retirement trigger cannot remove them. A local hall is not a private multiplayer hall, and losing a multiplayer connection does not turn that shared hall into an offline save.

## 2. Player experience and design pillars

The intended experience is a lively market of distinct restaurant businesses. A player should understand why a rival is attracting a queue, notice that a shared ingredient is becoming expensive, and have several credible responses: change prices, promote another recipe, improve service, change staffing, or invest in another cuisine.

1. **Competition through business decisions.** Rival purchases affect supply and costs. Rival menus, prices, service, and awards affect customer choice. Repeated clicking and connection speed should offer little economic advantage.
2. **Management from the beginning.** Players hire and direct workers rather than personally cooking meals. Automation makes a configured business repeat its plan; it does not remove the need to choose a good plan.
3. **Readable causes and consequences.** Financial reports and customer feedback explain losses, missed sales, waste, and queue problems. The 3D hall makes the same state visible.
4. **A worthwhile game at any population.** NPC rivals use the same economic rules. The hall remains interesting during the early period when only one human is playing.
5. **Growth with operational tradeoffs.** More stalls increase reach and throughput, but also rent, staffing requirements, and exposure to shortages. Expansion does not automatically manufacture new customers.
6. **Failure without account elimination.** A restaurant can fail permanently while its owner continues playing. A fresh business starts fresh; the owner's history remains honest.

The tone is energetic and competitive, with the warmth and activity of a busy food hall. The cuisines should have distinct identities without reducing their cultures to caricatures.

## 3. Terms, ownership, and capacity

| Term | Meaning |
| --- | --- |
| Account / owner | The human identity that persists across successful and failed businesses. |
| Hall | An independent physical layout, economy, customer population, and admission limit. |
| Restaurant / business | A named venture owned by one account in one hall. It holds the business's finances, stock, staff, recipe unlocks, and history. |
| Stall / location | One physical trading location belonging to a restaurant. Each expansion consumes another stall slot. |
| Station | A preparation or finishing work position inside a stall. |
| NPC restaurant | A server-controlled competitor, using the same restaurant and stall rules. |
| Visitor customer | A human playing the dining side of the game without needing a restaurant-owner account or invitation. |
| Visitor helper | An unlicensed human temporarily controlling an authorized staff position through a short shift; ownership and management permissions remain with the restaurant owner. |
| Connected owner | A distinct authenticated human owner currently present in the hall with a non-terminated venture and at least one paid stall lease. The stall need not be open. Multiple windows/devices count once; spectators, unlicensed guests, and licensed owners with no current lease do not count toward NPC retirement. |
| Operating stall | A stall accepting customers. Connection status and operating status are separate. |

Proposed ownership rules:

- One account may have one non-terminated restaurant in the public hall, including a distressed, dormant, or temporarily unlocated restaurant. Only a terminated bankrupt venture permits a fresh starter grant; reopening a solvent venture does not. A restaurant starts with one stall and can grow to three in the initial release. The three-stall limit is tunable.
- All locations of a restaurant share cash, inventory storage, staff roster, and recipe unlocks. Each location has its own menu, prices, equipment, staffing assignments, queue, and service results.
- A restaurant can operate different cuisines at different locations. Each stall specializes in one cuisine at a time; changing cuisine requires a refit and a temporary closure.
- The hall contains exactly 150 leasable stall slots at full capacity. Human stalls, expansion stalls, NPC stalls, and stalls reserved during setup all count toward this limit. Shared seating is outside these slots.
- Acquiring a lease requires an atomic capacity check. Two simultaneous purchases cannot obtain the same slot or exceed capacity.
- A full hall offers a waiting list rather than silently exceeding capacity or creating another public hall. Private halls remain later work.

Bankruptcy applies to the shared restaurant business, including all of its stalls. Closing one weak location is an alternative to losing the whole business.

### Invitation tree and account access

Account identity and invitation ancestry persist across business failure, recovery, and restaurant restarts. Owner admission has two routes: redeem an invitation, or successfully complete a visitor staff shift and obtain approval of a restaurant-license application. Visitors can inspect the hall, dine, and accept authorized shifts without either. A guest profile supports dining credit, work history, and applications before joining the owner tree. Either admission route grants the owner role and restaurant license; neither reserves a stall or guarantees immediate space. Existing owners retain their license after bankruptcy and when signing in on another device.

Each owner account records one immutable `inviter_account_id`, or an explicitly seeded root origin. For an approved license application, the proposed tree parent is the approving seed/admin owner account, recorded as its admission sponsor; retain `admission_route` to distinguish this from invitation redemption. The result is a rooted forest: no self-invitation, multiple parents, cycles, or reparenting after a restaurant restart. The tree belongs to identity across the service, not to a particular restaurant, stall, or future private hall. NPCs have an explicit system-controlled principal and never issue, earn, or redeem human account invitations or human restaurant licenses.

A durable identity has one canonical principal with optional guest and owner roles. Invitation redemption or license approval atomically adds the owner role, license, and tree parent to that principal; it does not create another wallet or merge unrelated profiles. Verified-email uniqueness covers both roles. A collision directs the visitor to authenticate the existing principal; it never silently transfers a guest balance or attaches somebody else's owner account. Losing an unlinked credential does not authorize recreating that principal from its public name. Anonymous profiles on unrelated devices cannot automatically be proven to represent the same person; aggregate economic limits do not rely on that assumption.

Public browsing needs no durable guest profile. On the first dining/work action, a rate-limited bootstrap flow binds a server-issued device credential to one guest principal atomically; a lost-response retry from that device recovers it instead of creating another wallet. This dedicated bootstrap grants only guest capabilities. Invitation redemption/promotion uses its separate device-bound admission flow; license approval targets an already authenticated applicant principal. No admission path trusts a client-selected principal ID or treats knowing a public name as authentication.

Seed accounts receive three available invitations. Ordinary owners admitted by either route start with none and earn issuance capacity through qualifying restaurant operation. The confirmed earning period is 7 cumulative game days, or 168 game hours, of solvent trading: 7 real hours of qualifying service. Cleaning never qualifies, so elapsed waiting time is longer than seven real hours and depends on the starting time and chosen service windows; forecasts use the actual schedule. Accrual runs once per owner, not once per stall. Proposed eligibility requires an open, staffed stall offering a feasible main dish, no unpaid operating obligations, and at least one completed simulated-customer meal in the preceding game day. Eligibility boundaries are evaluated against recorded hall time. Qualifying intervals accumulate; closed, dormant, distressed, or activity-ineligible intervals add no time. A 12-game-hour daily opening schedule therefore needs at least 14 elapsed game days to accumulate 7 trading days.

Signing in, clicking controls, buying equipment, founding another restaurant, and merely keeping a socket open do not qualify. Player-enabled automation can qualify through actual service under the same rules as connected play. Guest-funded meals and helper attendance do not supply the simulated-service activity gate. The earning requirement is fixed rather than population-scaled. Any future population-based adjustment must be balance-tested using human-owner counts, excluding NPCs and additional stalls.

Accrue each interval using the eligibility that actually held during it. A first qualifying meal enables future accrual; it cannot retroactively qualify the preceding day. Split intervals at opening/closure, staffing/stock/solvency changes, and expiry of the last simulated-meal activity gate. A sale exactly when an old gate expires can enable the following interval without granting time for an earlier ineligible interval.

Available entitlements plus issued, unused invitations are capped at three per ordinary account across the service. Issuing reserves an entitlement. Successful redemption consumes it; expiration or explicit revocation of an unused invitation restores it once. Closure or temporary ineligibility pauses partial progress. Reaching the combined cap clears partial progress and banks no further time; ordinary issuance keeps the combined count unchanged. Business replacement resets partial earning progress but preserves the account's inviter, already earned quota, outstanding invitations, and history; it does not create another seed grant.

An invitation is a high-entropy single-use code or recipient-addressed email link. Store only credential hashes. Shareable codes can create a device account without mandatory email; email delivery must not reveal a recipient-authentication credential to the inviter. Proposed validity is 72 unaccelerated service hours, excluding platform downtime. Three Feud Hall game days would be only three real hours and must not silently become the invitation lifetime. Show time remaining, status, available quota, earning progress, and the next action needed.

Redemption, account creation, session establishment, parent linkage, quota consumption, and acceptance notice form one atomic transition. Concurrent redemptions cannot create two accounts; expiry/revocation cannot also refund an entitlement already consumed. A response lost after commit must be recoverable through the original device-bound redemption attempt. A retry from another device cannot use a spent invitation to impersonate its invitee. Retrying after session revocation cannot recreate access. Keep invitation redemption separate from account recovery.

Use durable revocable device sessions. Optional verified email linking and magic-link sign-in provide recovery and cross-device continuity on web and desktop. The linking operation proves ownership and rejects email collisions without silently merging accounts. An unlinked owner receives a clear prompt before accumulating substantial assets: losing the only device credential means losing access, and out-of-app notices cannot reach an account with no verified contact method. Account recovery retains restaurant history and the invitation parent.

Email-link previews and GET requests must not consume a credential; require an explicit confirmed redemption. Limit issuance, redemption, and delivery attempts. The delivery adapter sends from a durable outbox after commit; it never sends a successful invitation for a transaction that rolled back. Retries use a stable delivery identity and report provider uncertainty honestly.

Invitation relationships grant no access to another owner's finances, policies, or login credentials. A permissioned review can inspect ancestry as context for confirmed abuse, but relationship alone is not evidence of wrongdoing. NPC competition, shared cuisine, or ordinary family/friend invitations must not trigger automatic subtree punishment. Operator seeding and quota grants are explicit, audited, idempotent maintenance operations; operator status is never inherited through the tree and grants no trading, lease, or bankruptcy advantage.

### Restaurant licenses and applications

A successful visitor staff shift unlocks **Apply for a restaurant license** on the same profile. Applying is optional and explicit; completing work does not automatically submit an application or grant ownership. A valid invitation remains an alternative route that requires no qualifying shift or application review.

Proposed success means reaching the end agreed at shift acceptance, including a disclosed truncation at the backing worker's scheduled break/end or 03:00 cleaning cutoff, with at least one server-validated helper-selected handover completed during that shift. A submitted selection alone is not a completed task. A shift ended early by leaving, disconnect, actionable idleness, owner intervention, closure, safety stop, employer failure, or recovery does not qualify. A full shift spent entirely on ready standby earns its normal wages but lacks the task proof. Show these criteria and progress before and during work; nonqualifying endings are not misconduct and the visitor may try again. Ordinary corrected input mistakes do not invalidate an otherwise successful shift. At a shared deadline, normal service completion precedes shift-end evaluation except at the hard 03:00 cleaning cutoff, when no customer service can complete. A helper whose accepted end is 03:00 can qualify using tasks completed strictly earlier.

Workforce owns the completion proof: principal, hall/restaurant/shift IDs, accepted start/end, completed qualifying tasks, actual end, and end reason. Successful completion, final wage settlement, and identity eligibility commit atomically across the hall and identity streams. Neither the employer nor the client can mark an arbitrary shift successful. One qualifying shift is sufficient; eligibility persists through session changes and does not expire with a game day or an employer's later bankruptcy. Existing owners need no application.

An eligible authenticated guest may submit one pending application across the service, with an optional short motivation. States are **pending, approved, rejected, withdrawn, or superseded**. Pending applications have no accelerated-time expiry; review is manual with no promised response time. The applicant can see their status, submission time, qualifying shift, and decision reason in their own inbox. They can withdraw, or explicitly reapply after rejection/withdrawal subject to service-time rate limits; prior attempts remain linked and eligibility need not be re-earned. Submission retries do not create duplicate queue entries. Verified email is optional, and approval can occur while the applicant is offline.

Seed players and admins receive an explicit `review_license_applications` capability. Grant it to configured launch seed accounts and designated admin owner accounts; invitation descendants and newly approved owners never inherit it. Reviewers must have a valid owner-tree node so approval has an unambiguous sponsor. The private, paginated queue shows applicant display name, submission time/age, qualifying shift evidence, human/NPC employer label, motivation, and application decision history. It exposes neither credentials/contact details nor private employer finances. Reviewers can approve or reject with an applicant-visible reason; rejection requires a reason. No self-approval. Review rights grant no trading or lease advantage.

Approval rechecks current reviewer authority, pending application/version, valid completion evidence, and the applicant's unlicensed state against authoritative identity facts. One atomic transition records decision and reviewer, grants the ordinary owner license/role, assigns the immutable sponsor parent, and writes the applicant's durable notice and command receipt. It consumes no invitation entitlement and grants no outgoing invitation quota, restaurant, starter capital, lease, or seed/admin powers. The applicant then follows normal setup or the full-hall waiting list. Concurrent reviews yield one terminal decision. If invitation redemption grants the license first, it atomically supersedes the pending application; later approval cannot reparent or grant again. If approval wins first, an attempted invitation redemption is rejected without consuming its code or quota. Withdrawal/rejection races follow the same expected-version rules. Recovery reconstructs eligibility, applications, authority, and decisions without reissuing licenses or notices.

## 4. Core loops and the first session

### Moment-to-moment management

Observe demand and margins, adjust a menu or policy, watch staff execute, and inspect the result. Typical interventions are changing a dish's price, moving a worker, authorizing a purchase, sending someone on break, or temporarily removing an unprofitable dish.

### Business cycle

Forecast demand → buy ingredients → schedule staff and opening hours → accept and fulfill orders → collect revenue → pay operating costs → review profit, waste, satisfaction, and missed demand → reinvest.

A five-to-fifteen-real-minute active session should contain several useful choices and visible consequences. Target a new interpretable development or opportunity every one to three real minutes during trading, through changing demand, stock, service, staffing, or rival behavior. This is a playtest target, not a requirement to interrupt the player with a timer or force repetitive clicking. Basic restock and work policies handle routine repetition. Market changes, customer demand, and NPC decisions provide activity even when the human population stays small.

### Long-term progression

Develop a recognizable restaurant, learn additional recipes, improve equipment and staff, pursue selected milestones, compete for awards, and expand into other stalls in the same hall. There is no mandatory ending, global reset, or single prescribed route through these goals.

### First-session flow

Visitors can choose **Visit as a customer** immediately: browse the hall, inspect menus and prices, choose an open human or NPC stall, place an order, follow its preparation, and receive their meal. They can also choose **Help at a stall**, accept an available shift, complete counter tasks, and earn dining credit. A successful shift offers **Apply for a restaurant license**, followed by an application-status view while awaiting seed/admin approval. NPC restaurants offer a starting source of work when few human owners are present. These loops are detailed below. Becoming a restaurant owner is a separate optional path:

1. Inspect the public hall and obtain a license through invitation redemption or an approved application. Continue on the same principal and see human and NPC competitors. An existing owner signs in to the same account; a full hall offers the waiting list before charging setup costs.
2. Name a restaurant and choose a starting cuisine through the equal-area world map, with the twenty-five available cuisine regions highlighted and an equivalent searchable list. Preview its equipment, ingredient exposure, and starter recipe before committing.
3. Compare available stall locations by foot-traffic exposure, rent, holding cost, setup cost, and estimated break-even sales. Choose an affordable location and receive the standard starter package. Starting locations have meaningful, openly disclosed tradeoffs; the game does not silently assign a superior location.
4. Review the supplied staff, basic shift coverage, opening hours, menu price, and initial stock in the ordinary business overview. A persistent service-readiness panel explains actual blockers, costs, and the break-even estimate; it is not a tutorial checklist that must be completed in sequence.
5. Open the stall. Staff automatically prepare and serve incoming orders. The first sale should occur within two real minutes under normal opening conditions outside cleaning; onboarding during cleaning shows the 05:00 reopening countdown and allows setup/planning immediately.
6. Inspect a clear operating report, make a pricing or staffing decision, and see the effect.
7. Before leaving, see whether the business will close or remain open under explicitly enabled automation, along with the expected costs and safety limits.

Before final confirmation, name/cuisine/location selections are an onboarding draft. A slot reservation counts toward capacity but creates no business, fees, or starter grant; it expires after ten unaccelerated service minutes without extending merely because a page reloads. Final confirmation atomically creates the venture, grants its starting capital once, pays the disclosed setup/stock costs, and acquires the lease. A confirmed paid lease is not subject to the draft timeout.

Allow one active onboarding/vacancy-offer draft per principal per hall, across
devices. Switching an unconfirmed slot atomically releases the old claim and
does not extend that draft's original deadline or bypass waiting-list priority.

Setup is recoverable until the first opening: the original unused starter kit can be exchanged for another starter cuisine at its published price difference, without another grant or replenishment of used stock. Ordinary market purchases do not become refundable starter stock. In-context onboarding uses real decisions and outcomes; it never simulates free sales, pauses the shared hall, or awards tutorial-only economic advantages.

## 5. Time, opening hours, and owner absence

### World clock

One game day is 24 game hours and lasts 60 real minutes. Therefore one game hour lasts 2.5 real minutes and one game minute lasts 2.5 real seconds. An eight-game-hour shift lasts 20 real minutes.

The hall clock is authoritative: shared by all multiplayer participants and owned by the local simulation in single-player. It drives opening hours, meal periods, staff schedules, spoilage, bills, award reviews, and research or refit durations. The UI shows both game time and real time until the next relevant event. The default daily demand curve includes quieter periods and distinct lunch and dinner peaks; players may choose their own opening windows.

Use three explicit clocks; an unqualified duration in content must identify its clock before that content is enabled:

| Clock | Rate and use |
| --- | --- |
| Hall time | 24× real time while available: cooking, patience/freshness, wages, opening/cleaning schedules, replenishment, daily budgets/reviews, and invitation earning. It advances during scheduled cleaning. |
| Available-service time | 1× real time while the authoritative service is ready: invitation validity, distress recovery, dormant leases, setup reservations, absence grace, helper shift limits, and visitor transfer-limit windows. Pauses during platform downtime. |
| Wall/monotonic time | Actual time: security credential expiry, network liveness detection, and operational monitoring. Credentials do not gain validity during an outage. Liveness detections produce explicit domain transitions at the current available-service time. |

References to real-hour/day gameplay deadlines below mean available-service time unless explicitly labeled security wall time. In multiplayer, clients cannot accelerate these clocks through local timestamps or frame rates. A local single-player authority advances them only while running and never from time spent closed. Replay restores recorded clock facts; live time resumes only after recovery reconciliation.

Proposed calendar boundaries are midnight game time: a calendar game day is
`[00:00, 24:00)`, and day-indexed demand forecasts and purchasing budgets change
once at 00:00. Initialize a new hall at day 0, 00:00; its first seven-day award
review is at day 7, 00:00, then every seven days. These boundaries differ from
the 03:00 operating-report period and cumulative invitation progress. The first
report covers only the available history since initialization, labeled as a
partial period; it invents no earlier costs or sales. Other replenishment and
content schedules must declare their own clock and boundary explicitly.

### Daily cleaning closure and planning

The hall is closed to customers every game day during **[03:00, 05:00)**. At 05:00 customer access becomes available again. These two game hours take **five real minutes** of available service at the confirmed 24× pace. This is a scheduled part of the running simulation, not platform downtime: both gameplay clocks keep advancing, stock ages, paid leases incur their closed holding fee, and ordinary service-time deadlines continue. A platform outage still pauses the clocks, preserving the remaining cleaning interval rather than charging or skipping it by wall time.

At 03:00 all human and simulated customers leave; no arrivals, orders, cooking for customers, counter service, or visitor helper work are permitted until 05:00. Warn before closing and show the countdown in menus and shift offers. Admission requires an expected completion strictly before 03:00 and binds an order deadline no later than that boundary. At the cutoff, cancel any remaining orders, release unused stock and guest funding reservations, record already consumed food as waste, and settle earned helper wages exactly once. Do not carry a dining queue or prepared meal into reopening. Scheduled-cleaning cancellation alone does not count as a service failure for competitive reputation/awards; earlier operational failures still do. The hard customer cutoff takes precedence over service at exactly 03:00.

Helper offers are truncated upfront to 03:00, with the shorter paid duration shown before acceptance. Reaching that agreed end with a completed qualifying task can still be a successful shift for licensing; newly arriving guests see when jobs resume. All restaurant production staff are off duty during cleaning, without production wages. Roster forecasts mask 03:00–05:00 even for shifts spanning midnight; fatigue recovers under the ordinary off-duty rule, and only valid scheduled coverage resumes at 05:00. Hall cleaning is automatic and covered by existing operating overhead; it adds no launch cleaning minigame, staffing requirement, or separate surprise charge. Normal closure rules stop routine automatic restocking and cancel unfilled automatic purchases; explicit manual purchases can be made during cleaning under the usual budgets and capacity rules.

Players can remain signed in to review reports, configure prices/menus/substitution policies, buy stock manually, schedule staff, arrange upgrades, apply for licenses, and review applications if authorized. Visitors stay in a non-dining lobby/status view; public inspection and account actions remain available, but the 3D customer floor is empty. New owners may finish setup and queue a scheduled opening for 05:00. No one must acknowledge a report to reopen.

Publish a daily operating report at 03:00 covering the preceding 24 game hours, from the previous 03:00 to the current 03:00. This gives owners the completed trading period at the start of planning; include the preceding cleaning interval's actual holding costs. During cleaning show current planning-period costs separately. Calendar-day purchasing budgets and award schedules retain their declared boundaries, labeled distinctly from the report period; opening reports does not reset them. Reports remain accessible at any time.

Owners choose shorter or split service windows outside cleaning, up to 22 game hours daily. Overnight demand may still offer a niche outside 03:00–05:00. At 05:00, eligible scheduled stalls can reopen with sufficient staffing/stock and either a present owner or explicitly enabled unattended operation. Cleaning does not turn on automation, reopen a manually closed stall, clear an absence hold/safety stop, or reverse distress, dormancy, bankruptcy, or refitting. The absence grace continues through cleaning; planning presence counts as owner presence under the ordinary authenticated-session rules.

### Operating states

Hall customer access, restaurant lifecycle, and stall operating mode are separate fields. The hall cleaning gate overrides every stall's ability to admit diners or perform customer service without erasing its saved operating schedule or safety/absence holds. Distress, bankruptcy, and dormancy are business-wide and override every stall; ordinary closure, refit, and local staffing safety stops affect only the selected stalls. Shared-cash or business-loss safety limits stop all affected business spending/stalls. Each configured safety rule declares its scope and remains latched until reviewed.

| State | Customer orders | Purchasing and staff | Costs and exit |
| --- | --- | --- | --- |
| Setting up | None | Configure equipment, stock, and roster | Confirmed lease uses holding costs; only an unconfirmed draft reservation expires. |
| Open | Accept eligible new orders outside cleaning | Execute current assignments and authorized policies outside cleaning | Normal operating costs while serving; the hall cleaning overlay uses closed holding costs and off-duty staff. |
| Closing | No new orders | Complete or settle accepted work, then release staff | Charge work actually performed; transition to closed. |
| Closed | None | Manual management/purchases allowed; routine restocking paused; staff off duty | Reduced lease holding cost; inventory still ages. |
| Refitting | None | Paid equipment/cuisine work; no normal staff production | Retains its slot; holding fee and disclosed refit charges apply. |
| Safety stopped | None | Settle accepted work; stop discretionary spending | Closed costs apply; owner must review the cause. |
| Distressed | No new orders | Recovery and liquidation controls remain available | An unpaid obligation has triggered the recovery process. |
| Bankrupt | None | No further trading or spending | Immutable failed-business record; leases released. |
| Dormant | None | No active leases or shifts | Inactive solvent business retained for possible reopening. |

### Closing by default

When the last authenticated session for an owner disconnects, a two-real-minute grace period begins. If they do not return and unattended operation is disabled, their open stalls enter closing. Another visitor's customer/helper session does not keep that owner's business attended. No new customer orders are admitted after closing begins. Accepted orders are completed where possible or resolved under the cancellation rules. Routine automatic purchasing stops when closing begins.

Other owners' sessions do not keep this restaurant open. Multiple devices do not trigger closure until the last session is gone. A server-detected connection loss uses the same rule as quitting; reconnection within the grace period cancels the pending closure.

After closure, scheduled opening cannot override the absence policy. On returning, the owner explicitly reopens or resumes the schedule; the game does not retrospectively execute missed openings. Opted-in unattended operation can follow its schedule without a connected owner.

This attendance hold differs from ordinary scheduled closure or hall cleaning: those can reopen at the next permitted window when the stall schedule, attendance, and opted-in automation allow it. A safety stop also needs explicit review; neither a new game day nor a helper can clear its latch.

Entering closing withdraws helper offers, ends active helper control, stops automatic restocking, and cancels its unfilled automatic purchase requests in the same transition. Pending manual orders survive only if explicitly authorized to remain valid while closed. Accepted meals finish through automatic coverage, subject to their existing patience/freshness deadlines; infeasible remaining work cancels under the ordinary waste/reservation rules. Closing cannot wait forever for an unavailable worker. Once jobs settle, staff go off duty and the holding rate begins. An attended closed stall can still make new explicit manual purchases.

Closing does not erase obligations or pause stock aging. Proposed cost treatment is shift-based wages for time worked, ordinary rent while open, and a substantially smaller holding fee while closed. The finance screen must explain this before the player leaves. It must not silently charge a full staffed trading day while the default policy has closed the restaurant.

### Optional unattended operation

An owner can explicitly enable unattended operation for selected stalls. They configure opening hours, shifts and breaks, purchasing budgets and price ceilings, menu availability, and pricing policies. A live preview shows expected working capital and the enabled stop conditions.

Useful safety rules include minimum cash reserve, maximum purchasing spend per game day, maximum ingredient unit price, minimum dish contribution margin, missing staff coverage, and maximum cumulative operating loss since activation. Defaults should be conservative and editable. The closure action and residual bills must be visible; a safety stop reduces further exposure but cannot guarantee profit or prevent every bankruptcy.

The same automation controls are available while connected. Unattended operation has no artificial efficiency penalty or production bonus. Reconnecting does not clear a safety stop automatically. Owners can always choose manual purchasing or fixed menu prices instead of automated policies.

Initial pricing policies are fixed price or bounded cost-plus using current replacement ingredient costs. Owners set minimum and maximum menu prices and a maximum adjustment frequency. Automatic pricing cannot assume that diners will accept the resulting price. Restock policies similarly specify target stock, purchasing priority, daily spend, and maximum unit prices; they cannot spend outside those permissions.

### Service interruptions

The following availability and absence policies concern multiplayer. An individual player's network interruption does not pause that shared hall. A server or authoritative persistence failure does: uncommitted economic advancement stops for everyone. A prolonged unobserved scheduler gap also enters recovery rather than silently charging catch-up; the proposed threshold is five real seconds, to qualify under load. Recovery resumes from committed clocks without charging wages, spoilage, rent, or missed sales for unavailable time. Player-rights deadlines also pause, so an outage cannot exhaust a recovery window or unused invitation. A historical-report read or audio/rendering failure is local to that feature and does not stop an otherwise healthy economy. The interruption and recovery interval appear in the hall notice feed.

## 6. The shared hall and expansion space

The full hall has 150 predefined slots, grouped into a row of ten rooms (below). The initial camera frames one room rather than requiring a new player to traverse a mostly empty building. Every location remains part of one economic hall; rooms are not separate markets, and the hall-wide arrival pool does not grow when a room opens.

Shared seating, walkways, signage, and crowds communicate a common place. Proximity to entrances, main walkways, or shared seating can contribute to a location's published foot-traffic exposure. Physical seating capacity and pedestrian collisions remain presentation features in the first release; economic queue capacity and service times are explicit server rules.

### Rooms

In this section a **room** is one of the ten small halls. Player-facing text calls them "Hall 1" to "Hall 10" (「ホール1」 to 「ホール10」); "the hall" keeps meaning the whole economic place.

**Owner decisions (2026-11-13):**

- The hall is a row of ten square rooms, each holding up to 15 stalls around its walls, with the centre kept for tables. There are no island blocks in the middle of the floor.
- Each room has its own entrance from outside.
- Neighbouring rooms are joined by doorways that stay shut until the next room is in use. At the start only room 1 is used.
- The next room opens once every spot of any one quality class is taken across the rooms already open.
- Location quality is tied to where a stall actually stands.
- The scene draws roughly one room at a time; directly connected open rooms may be shown too.

**Spots and quality (proposed design defaults).** Each of the 150 spot IDs has a fixed room and a fixed position, so a stall never moves. Room membership is versioned catalog rule data, because the server decides which spots can be leased; the coordinates of a position are client presentation data. The quality class of each spot is unchanged: 40 quiet (`s001`–`s040`), 60 standard (`s041`–`s100`), 35 busy (`s101`–`s135`) and 15 prime (`s136`–`s150`). Fifteen per room does not divide those evenly, so rooms alternate: odd rooms hold 4 quiet, 6 standard, 3 busy and 2 prime; even rooms hold 4 quiet, 6 standard, 4 busy and 1 prime. Within each class, ascending spot IDs fill rooms in order, so room 1 holds `s001`–`s004`, `s041`–`s046`, `s101`–`s103`, `s136` and `s137`.

Quality follows position (designer's call, owner saw it). Positions run clockwise from the north-west corner; the entrance is in the middle of the south wall and the doorways to neighbouring rooms in the middle of the west and east walls.

| Position | Where | Class |
| --- | --- | --- |
| 0, 6, 9, 12 | Corners | Quiet |
| 1–5 | North wall | Standard |
| 7, 8 and 13, 14 | Beside the east and west doorways | Busy |
| 10, 11 | Beside the entrance | Prime |

Odd rooms have three busy spots, so position 13 is standard there; even rooms have one prime spot, so position 11 is standard there. The end rooms have a blank wall where a further doorway would be. The exposure factor of each class is unchanged.

**Which rooms are open (proposed design default).** "Open" is derived from committed state and never stored, so the lease check and every view agree:

- Room 1 is always open.
- Room *k*+1 is open when rooms 1..*k* are open and, for at least one class, every spot of that class in rooms 1..*k* is leased.
- A room is also open when it, or any later room, holds a lease or a draft reservation. First-location offers are draft reservations. This keeps the row contiguous in halls that had leases in later rooms before the rule arrived, and stops a room closing on a tenant.
- Drafts do not count as leased for the opening test, so an expiring draft cannot make a room flicker open and shut. A room can close again when a departure reopens a class and the room is empty.

**What a closed room means (rule change).** A spot in a closed room cannot be reserved, leased, offered from the waiting list or chosen by a computer-run owner. Reserving such a spot is refused as unavailable; creating a restaurant or adding a location there is refused with `room_closed`. The lease list, the "to let" bays and the computer-run planner see the same open rooms. When a lease opens the next room, the waiting list is offered spots in it in the same transition, in FIFO order. The newcomer vacancy reserve below is still not implemented in the server; the room rule does not add it.

Odd rooms have two prime spots and even rooms one, so prime is the class most likely to run out first and open the next room while the current one is sparse. **Owner decision (2026-11-13):** a new hall does not start with a computer-run restaurant on a prime spot. The catalog's "premium" computer-run profile prefers standard spots instead of prime, which also applies whenever that profile chooses a spot later. Scarcity rent, below, is the second answer: a strong nudge for classes to fill evenly, not a guarantee.

### Location quality and lease pricing

Locations differ economically from the first release. A stall on a busy main aisle or near an entrance receives greater exposure to the shared diner pool than a quieter side-aisle stall, and pays higher rent. The map and lease list show the same exposure rating and costs, with a plain explanation of the location's advantages. Camera position, rendering detail, and a client's frame rate have no economic effect.

All initial slots share the same baseline equipment footprint. The tier changes traffic exposure and lease charges, not an undisclosed station capacity or staff-skill bonus. Equipment improvements are priced and shown separately.

Proposed initial tiers illustrate the tradeoff; their values require balance testing. The rents are each class's base rent; the quoted rent rises above it as the class fills (see [scarcity rent](#scarcity-rent)):

| Location tier | Foot-traffic exposure factor | Base open-state rent per 24 game hours | Base closed holding fee per 24 game hours |
| --- | ---: | ---: | ---: |
| Quiet side aisle | 0.8× | $80 | $8 |
| Standard aisle | 1.0× | $100 | $10 |
| Busy main aisle | 1.25× | $150 | $15 |
| Prime entrance area | 1.5× | $220 | $22 |

The exposure factor affects the likelihood of a simulated diner considering/choosing a stall, alongside cuisine preference, price, reputation, and wait. It is not a guaranteed sales multiplier. All locations draw from the same finite hall-wide arrival pool; a premium lease redistributes opportunity rather than spawning extra customers. A well-run inexpensive stall can outperform an expensive location with an unsuitable menu or poor service. Human visitors choose their own stalls freely.

First-stall setup, expansion and reopening show a schematic floor plan for each open room, with the entrance, seating, and vacant spots in their hall positions. The map and room-grouped list share a selection. A class legend explains the traffic and cost tradeoff, and the selected spot shows its live exposure, open rent, holding fee, and setup fee. Players use the reserve or lease button to submit their choice. Halls without room data show the list and class explanations.

Before confirming a lease, show its exact open and closed rates, prorated costs for the chosen opening schedule, upfront charges, exposure factor and reasons, projected sales as an estimate, and break-even meals at the selected menu margins. Compare the selected location with available cheaper options. At an $8 contribution per meal and the maximum 22-game-hour trading schedule plus two hours of cleaning holding fees, the busy-aisle daily premium is $46.25 (six extra meals) and the prime premium is $111 (fourteen extra meals). With twelve hours open and twelve closed, the respective combined rent/holding premiums are $27.50 and $66, requiring four and nine extra meals. These are cost comparisons, not promises of demand; quotes use the actual schedule and pinned lease terms.

Leases are quoted, not bid for. Players choose among available, affordable slots in open rooms for both their first location and expansions. Keep a useful mix of lower-rent and premium locations in the layout, with the newcomer vacancy reserve applying to affordable locations where possible. If no suitable affordable slot is free, show the actual alternatives or waiting list rather than assigning an unaffordable lease. NPCs pay the same quoted rates and choose locations within their budgets using the current quote. That budget choice is not implemented today: the computer-run planner (`Planner.choose_slot/3`) picks a spot by preferred class and ignores rent.

Record the accepted slot, exposure profile/version, rent, and holding terms with the lease. Proposed first-release terms remain fixed for that lease; changes to future location pricing do not silently reprice existing leases. Closing reduces the charge to the lease's recorded holding fee, so occupying a premium slot still has a higher cost while closed. Acquiring a different location uses the normal lease/setup and surrender rules.

### Scarcity rent

**Owner decision (2026-11-13):** a quality class's rent rises as that class's relative availability falls. This replaces the earlier proposed default of published fixed tiers. The confirmed rule that better locations cost more, shown before choosing, still holds.

Designer's calls the owner saw:

- Only new quotes carry the scarcity rent. A draft reservation or first-location offer holds the rent it was quoted until its existing deadline, and a lease records the rent it was quoted and keeps it. No existing lease, draft or accepted order changes terms, so an owner who signs when a class is nearly full keeps paying more than a neighbour who signs after the next room opens.
- The rise is capped.
- A class's quote always stays below the current quote of the next class up.

The quote is computed from committed state, counting only spots in open rooms. For a class with base rent *B*, *total* spots in the open rooms and *leased* of them leased (drafts do not count), with cap *C* in thousandths:

- if *total* ≤ 1 or *leased* ≥ *total* − 1, the raw rent is ⌊*B* × *C* / 1000⌋;
- otherwise the raw rent is ⌊*B* × (1000 × (*total* − 1) + (*C* − 1000) × *leased*) / (1000 × (*total* − 1))⌋, a straight line from *B* with nothing leased to the cap with one spot left.

Prime's quote is its raw rent. Working down from prime, each lower class's quote is the smaller of its raw rent and the next class up's quote minus the class gap. The holding fee scales by the same factor: ⌊base holding × quote / *B*⌋. Arithmetic is in integer minor units and every division rounds down; the rent shown, quoted and recorded is the same number. An expansion form sends the rent it showed; if the quote has changed by the time the owner confirms, the lease is refused with `quote_changed` and the form shows the new rent to confirm again, so an owner is never committed to a rent they did not see. Proposed tuning: cap 1.5× (`scarcity_cap_permille` 1,500) and class gap $1.00 (`class_gap` 100), recorded in the catalog's room rule.

Worked figures with only room 1 open (4 quiet, 6 standard, 3 busy, 2 prime spots):

| Leased | Quote |
| --- | --- |
| Nothing | Quiet $80, standard $100, busy $150, prime $220 |
| One of four quiet | Quiet $93.33 |
| Two of six standard | Standard $120 |
| One of two prime | Prime $330, holding $33 |
| Three of four quiet, no standard | Quiet $99, held $1 below standard's $100 by the class gap (raw $120) |
| Six of six standard, so room 2 opens | Standard $127.27 (six of twelve) |

When a room opens, the class has more spots, the leased share falls, and new quotes drop. The exposure factor does not change: scarcity affects what a spot costs, never how many diners pass it. Computer-run owners use the same quotes. A new hall's three computer-run restaurants stand on `s001` (quiet, $80), `s041` (standard, $100) and `s042` (standard, $110), all in room 1.

Every place that shows a rent shows the current quote, or for a held draft the held rent: the lease list, the "to let" bay, both location forms and the expansion estimate and break-even figures. Each adds one plain line in English and Japanese: how many spots of the class are taken and how far above the usual rent the quote is (the percentage rounded down), that it is the usual rent, or until when a draft holds its rent.

### Admission and dormant leases

Proposed admission rules reserve the final ten vacant slots for first-location applicants: expansions require at least ten vacancies after the purchase. The server does not implement this newcomer vacancy reserve yet. NPCs may relinquish a lease to admit a human instead of blocking entry, but the incoming owner acquires it only after existing work and lease commitments settle. A human never loses an active lease merely because the hall is popular. Draft reservations use the ten-service-minute setup rule above; draft expiry creates no failed-business record and cannot release an already confirmed lease.

Proposed waiting-list allocation is FIFO among licensed human principals seeking
their first current location, including dormant owners reopening without a grant.
Allow one active entry per principal, with acceptable location tiers selected
explicitly. A compatible vacancy goes to the earliest eligible entry before a
new direct applicant or expansion can claim it; NPC restoration cannot take that
offered slot. An offer uses the existing ten-service-minute draft reservation,
with a durable notice and the exact lease/setup quote, and consumes no money or
starter grant until confirmation. The offered lease/setup quote is held until
that reservation's deadline. Confirmation rechecks funds and lifecycle.
Declining or missing the deadline pauses the entry and releases the slot;
explicit rejoining goes to the tail. Reloads and outages do not extend or reset
its remaining service-time deadline. Changing preferences cannot improve queue
position. Queue status shows the applicant's own place and availability, without
exposing other applicants' private state; it promises no definite wait time.

To avoid permanent occupation by abandoned businesses, a solvent business with no trading and no owner management activity for seven real days becomes dormant. After settling work, its leases are released, its equipment is stored, and its remaining finances are retained. This is recorded as dormancy, not bankruptcy. An owner returning to a full hall joins the waiting list. Trading through opted-in automation counts as activity. The UI shows the inactivity deadline and a warning when the owner is present before it expires.

Surrendering the last stall likewise makes the solvent venture dormant. Dormant ventures retain their identity, recipe unlocks, stored equipment, and remaining cash, but no lease, staffed shift, automatic purchase, or helper offer. Stock still ages and is written off when spoiled. Reopening requires an available lease and its setup costs, without a new starter grant; the owner cannot create a second solvent venture alongside it. Closing a location is recorded separately from a failed business.

## 7. Competing for customers

### A finite pool of diners

The server generates one hall-wide arrival pool. Restaurants compete for this pool; each stall does not independently create a new crowd of paying customers.

Demand follows the announced meal-period curve, small seeded variation, and occasional announced trends. Proposed scale adapts to the previous complete game day's operating business equivalents, with a floor of three. One business contributes its fraction of the day's 22 customer-accessible game hours with at least one staffed, main-menu-eligible open stall, capped at one equivalent; NPC businesses use the same measure. Multiple stalls, devices, or replacements owned by the same human account cannot contribute overlapping extra equivalents. Fix the next day's scale at its boundary. Opening a second stall does not directly increase it; extended coverage may increase the business's single capped contribution. On a newly initialized hall, use the floor until a complete observation day exists.

The initial tuning target is roughly 90 potential diner arrivals per game day per established operating business equivalent, with a floor of three equivalents. This is an economic tuning input, not a guaranteed number of purchases. The arrival curve is zero during 03:00–05:00 and distributes the unchanged finite daily target over the remaining 22 hours; cleaning produces no queued arrivals or reopening catch-up surge. The arrival curve and starting cash must allow new businesses to survive the adaptation delay. The game must be tested at sparse, medium, and full stall occupancy.

**More real customers (proposed tuning).** The target feel is three or four orders waiting at a well-stocked stall in the lunch and dinner rush, one or two mid-morning and mid-afternoon, and a nearly empty hall overnight. A hall runs on the first column below until an operator applies the second through a [recorded rule change](ARCHITECTURE.md#the-recorded-rule-change); a new hall also starts on the first. The first column is what a hall uses now; the second is proposed tuning. Only these demand values are tuned. The pool stays finite and is not multiplied by stalls, and the segment budgets, patience and queue limit are unchanged.

| Value | Current | Chosen (proposed, not applied) |
| --- | --- | --- |
| Potential arrivals per business equivalent per day | 90 | 248 |
| Share of the day by hour, 00:00 first (proportions; the demand model normalizes them, and the chosen weights also equal arrivals per equivalent in each hour, summing to 248) | 2, 1, 1, 0, 0, 1, 2, 4, 6, 6, 8, 12, 14, 12, 8, 6, 6, 8, 12, 14, 10, 8, 5, 3 | 3, 2, 1, 0, 0, 2, 3, 5, 7, 9, 11, 19, 30, 19, 12, 12, 12, 14, 19, 28, 16, 11, 8, 5 |

The chosen day has a one-hour peak at 12:00 and at 19:00. The [report](superpowers/reports/2026-11-15-more-real-customers.md#the-chosen-values) gives the measurements behind these values. A sharper alternative (252 arrivals per equivalent, with 34 and 33 in the two rush hours) was measured beside it and is the owner's to choose instead: see [the choice between two day shapes](superpowers/reports/2026-11-15-more-real-customers.md#the-choice-between-two-day-shapes).

### Human visitor customers

Visitor customer play is part of the first release. A visitor chooses where and what to eat instead of having the server's preference model choose for them. Menus show price, availability, estimated wait, and dietary compatibility. Visitors can select optional dietary requirements before confirming a main; the chosen rules remain fixed for that visit. After submitting an order, the visitor can watch the stall prepare it, track its status, and receive/eat the completed dish. A lightweight guest session is sufficient; an invitation, verified email, or restaurant lease is not required.

These are genuine orders: they reserve ingredients, occupy staff/stations and queue space, and generate restaurant revenue only on successful service through the ordinary order pipeline. Human and NPC stalls are both eligible. The visitor cannot set a price, manufacture a completion, skip a queue, or access the owner's private state. Orders belong to the canonical guest principal; any currently authorized session for that principal can recover its order status, including after reconnect or verified recovery.

Owners may dine at competing human or NPC restaurants, but cannot purchase food or drinks from any stall of their own restaurant, including expansion locations. Hide owned stalls from checkout choices and meal comparisons; retain their public menus and hall inspection. Enforce ownership again when quoting and accepting a main/drink or dessert, so stale or direct requests cannot bypass the rule. Orders accepted before this rule remain bound to their original terms and settle normally, but cannot gain a new self-purchased dessert. Dining credit and prior helper earnings remain spendable at competitors.

Proposed funding combines a small server-issued virtual dining allowance with earned helper wages in a visitor's hall-specific dining wallet. Allowance grants draw from the bounded hall visitor fund; wages transfer value from restaurant payroll and do not mint another allowance. There is no real-money payment, cash-out, or discretionary gifting. Reserve each course's cost on acceptance, debit it on service, and release it on cancellation; this is a spending reservation, not advance restaurant revenue. A disconnect does not duplicate or automatically cancel an accepted order, and reconnecting retrieves the same order.

Hide **Claim daily allowance** once the principal has claimed it for the current
game day. Use the server's per-principal claim status, independent of the dining
wallet balance; spending the credit, reconnecting, or changing devices does not
reveal another claim. Show the action again on the next game day. Concurrent or
stale submissions still obey the authoritative once-per-day guard.

Allowance grants consume a bounded hall-wide issuance budget when issued, plus profile/session limits. Issuing a new credential, leaving credit unspent, or canceling a meal does not replenish that budget. Earned wages are funded by the employer and do not consume the allowance issuance budget; exhausting promotional grants cannot confiscate or invalidate previously earned credit. Both funding sources remain subject to normal order capacity, admission rate limits, and competitive-metric eligibility. Anonymous profile limits alone cannot establish unique humans; aggregate hall and employer limits are required.

Track wallet credit by source grant or payroll-settlement ID. Reserve exact funding slices with the order, using allowance credit before earned credit by default. Cancellation releases those same slices without issuing a new grant; service debits them exactly once. Earned credit remains on the principal through session changes and has no inactivity expiry in the first release. Report allowance-funded and wage-funded purchases separately from simulated demand. Only the server assigns demand/funding origin. Guest participation supplies no owner privileges or invitation issuance; an already authenticated owner's ordinary presence is still counted once under the owner rules.

A customer visit begins when the server admits a meal intent, not whenever somebody loads or browses the hall. Record it as one distinct visitor arrival with at most one accepted main, one initial same-stall drink add-on, and one eligible same-stall dessert under that visit. The accounting pool contains generated simulated arrivals plus bounded admitted visitor arrivals; a visitor is never also represented by a second simulated diner. Browsing, working, and replacing credentials do not increase baseline simulated demand. Any visitor feedback is shown separately from computed service results.

Proposed visitor admission allows one active dining visit per principal per
hall, across all devices, until main failure or the ordinary post-main/dessert
finalization. For human diners, admission and main acceptance commit together
after a valid confirmation; browsing and quotes create neither. A rejected
admission creates no visit or allowance. Starting another
visit after finalization consumes the normal admission limits; a canceled course
does not let the same visit accept a second main, drink, or dessert.

All genuine guest sales contribute to cash flow, operating profit, and workload. For the first release, only simulated-customer outcomes contribute to demand-affecting reputation, award qualification/scoring, and the invitation activity gate. This prevents uninvited profile creation from directly manufacturing competitive recognition. Cosmetic milestones may explicitly count either source, using real completed orders and ledger profit; their eligibility is defined in content. Owners see separate source breakdowns, and empty simulated history retains neutral reputation rather than treating guest-only service as failure.

#### Milestone 5 diner interactions

Give the diner a short **browse, order, follow, and decide** loop from the
same hall and visit screens.

- **Compare a few viable orders.** Filter by dietary profile and budget, and
  sort by estimated time to service or price. Offer a **New to me** view
  based on the diner's own served mains. Show the same open stalls, resolved
  dietary fit, current price, and estimated wait in the 3D inspector and
  stall list. Include a selected drink in the comparison total. Estimates can
  change with stock and demand. Reviewing an option holds no place or food.
  The existing checkout quotes the exact tray again before confirmation.
- **Follow the tray while exploring.** Show a compact status in Hall and
  My visit for queued, preparing, at the counter, and served. Explain that a
  revised estimate can reflect queue movement or a staffing change. Keep the
  visit and its status available while the player browses. A diner can change
  plans by canceling an eligible unstarted tray and confirming a new order
  under the ordinary admission rules. An order already in preparation stays
  bound to its confirmed terms.
- **Receive the meal and choose what comes next.** Highlight the pickup
  counter when service is committed. The diner can open the tray or receipt
  from the scene or My visit, then see an eligible same-stall dessert's price,
  wait, and remaining offer time, with clear accept and skip actions. Receipt
  viewing and avatar movement never gate service, payment, or dessert
  eligibility. A private tasting list built from served mains lets diners
  decide which cuisines to try on a later visit. It grants no credit or
  competitive recognition.

These interactions use the same visit, queue place, allowance and wallet,
and main/drink/dessert limits as ordinary dining. Preserve decisions and drafts
across view switches and reconnects. Both languages and the keyboard- and
touch-accessible HTML views show the same information and actions.

### Customer segments and decisions

Customers vary in budget, cuisine preference, quality expectations, and patience. Initial segments are value seekers, time-sensitive diners, cuisine enthusiasts, and quality seekers. These describe buying preferences rather than demographic stereotypes.

For each arriving simulated diner, the server considers eligible stalls and then main dishes within the selected stall. A main must be unlocked, offered, in stock or reservable, staffed, compatible with that diner's dietary requirements, and able to accept another order. Resolve the offered ingredient variant before checking compatibility. Dessert is considered only after a main is served, within that same visit, under the same dietary requirements and any remaining carbohydrate allowance. Dessert menu rows do not become additional entry choices or multiply stall appeal. The diner compares:

- Cuisine and dish preference.
- Price relative to budget and expected value, including the offered ingredient variant's expected quality.
- Restaurant reputation and current award recognition.
- The stall's published location exposure factor.
- Estimated wait relative to patience.
- Availability and the attractiveness of competing offers.

A bounded weighted-choice model selects a stall or the explicit **leave without purchasing** option, then selects an eligible dish at that stall. Derive stall appeal from its best-fitting eligible dish plus a separately bounded variety modifier; do not sum an unrestricted weight for every menu entry. Apply location and active prestige once at stall choice. Adding a duplicate or near-identical menu item cannot multiply foot traffic. A restaurant cannot force purchases merely by being the only open seller. Extremely low prices cannot create infinite demand, and a closed or ineligible stall has zero purchase probability.

Restaurant reputation summarizes recent service experience. Award recognition is a separate bounded modifier. Price sensitivity varies by segment: the cheapest dish should not always win, and an expensive dish needs a credible quality or preference advantage.

### Dietary requirements and menu reach

Dietary compatibility is a **hard eligibility filter**, independent of a diner's
value, speed, cuisine, or quality preferences. Price cuts, awards, location, and
an empty hall cannot persuade a diner to buy an incompatible dish. A stall with
no compatible feasible main has zero appeal to that diner. If no stall offers
one, record a departure with the reason **no compatible main**, without a
reputation penalty or an extra arrival. Unrestricted diners can still choose
vegetarian, vegan, or carbohydrate-restricted food. Only compatible eligible
dishes contribute to that diner's stall appeal and bounded variety modifier.

Proposed launch profiles and starting population weights are below. These are
game-balance hypotheses, not claims about real population prevalence. Sample
one profile per simulated arrival from the versioned distribution, separately
from its preference segment, and persist it with the visit. Profile shares
partition the existing finite arrival pool; opening a dietary menu does not
generate an additional pool of diners.

| Profile | Eligibility rule | Proposed share |
| --- | --- | ---: |
| Unrestricted | No additional dietary exclusion. | 60% |
| Vegetarian | No meat, fish/seafood, animal stock/fat, gelatin, or animal-derived rennet; eggs and dairy are permitted. | 20% |
| Vegan | No animal-derived ingredients, including eggs, dairy, and honey. | 10% |
| Carbohydrate-conscious | Served courses together must fit a declared per-visit carbohydrate ceiling. | 7% |
| Keto-style | The same rule with a stricter carbohydrate ceiling. | 3% |

Carbohydrate-conscious and keto-style are simplified game eating profiles, not
medical diagnoses or claims that one meal establishes ketosis. Do not label all
people with diabetes as keto customers: diabetes has no single required eating
plan, as explained by the
[American Diabetes Association](https://diabetes.org/food-nutrition/eating-for-diabetes-management).
Guests choose optional in-game requirements before confirming a main; collect
no diagnosis. Requirements can be combined in an authored profile, using the
intersection of its rules; do not independently sample flags into unintended
combinations. New combinations and their weights require content validation.

Compute compatibility from the **full resolved portion**, including sides,
broth, sauces, pantry packs, coatings, and the actual substituted products.
Version ingredient-origin facts and declared carbohydrate quantities with the
recipe/yield definitions. Missing or uncertain required metadata cannot count
as compatible. Dish names, owner-entered badges, or a vegetable garnish are
not proof. Approved substitutes still preserve the recipe's published dietary
claims; changes in carbohydrate content can additionally alter a variant's
eligibility for a carbohydrate-restricted profile. Never silently remove rice,
bread, sugar, or animal products to make an order qualify: a differently
described preparation requires deliberate authored recipe content.
Replacement batches for expired reservations must also match the bound
ingredient-composition definition; a new product definition with different
dietary facts cannot silently replace an accepted portion's ingredients.

Pin requirements, compatibility-policy version, carbohydrate ceiling, and each
accepted portion's composition with the visit/order. Main, optional drink, and dessert
share that ceiling: reserve the declared carbohydrate amount at course
acceptance, consume that allowance only on service, and release it on
cancellation without reopening a consumed course slot. A main/drink tray must
fit as a whole. An incompatible optional drink is omitted before acceptance or
requires a revised guest confirmation; an incompatible dessert
is unavailable to that diner; declining or lacking dessert still carries no
penalty. Guest requirement changes apply to a future visit, not an accepted one.
Stale ingredient or dietary declarations require a fresh confirmation.

Before enabling content, demonstrate at least one viable main in the existing
100-recipe catalog for every enabled profile, including each enabled combination.
Not every cuisine must serve every profile; specialization and underserved
demand are intended tradeoffs. Set both carbohydrate ceilings explicitly and
validate the stricter relationship, full-portion composition, portion value,
and recipe identity. Many current dishes include rice, bread, or noodles, so
their names alone cannot justify a keto-style badge. Do not enable a nominal
profile with no compatible recipe or expand the confirmed recipe count silently.
Dietary matching and hidden-diagnosis assumptions never replace normal stock,
price, staffing, freshness, or queue rules.

Menus and previews show server-derived compatibility badges and reasons in
English/Japanese. Owners see dietary reach estimates and aggregate served/missed
demand by profile, with ingredient-related exclusion reasons. Keep per-stall
consideration exclusions distinct from unique hall departures. NPC planners
can respond to the same public demand summaries and their own menu coverage;
they cannot inspect future diner profiles or receive free special ingredients.

### Orders, queues, and satisfaction

An accepted order binds one diner, stall, recipe/content version, resolved ingredient bill and substitution penalties, menu price, funding reservation, and deadline under a unique ID. Later menu edits cannot reprice it or change its ingredients/work definition. Queue length is capped and displayed as an estimated wait. Simulated diners have seeded patience. Human visitors instead see and accept a maximum service deadline and can cancel under the published rules; they do not receive a hidden random impatience draw. Disconnect alone does not cancel their order, but the accepted deadline still applies.

A human confirmation identifies the exact offered price, ingredient variant,
recipe version, dietary requirements/composition declaration, and maximum
service deadline. Revalidate those terms atomically
at acceptance; changed terms require a fresh confirmation, with no order,
spending, or stock reservation from the rejected attempt. A rejected command ID
keeps its original result; accepting a revised offer uses a new command ID.
Apply the same contract to main, drink, and dessert orders. Viewing a quote reserves
nothing and does not extend an existing dessert choice window.

Proposed voluntary cancellation is free while the course is waiting and
preparation has not started. Once ingredients are consumed, a human diner cannot
cancel voluntarily; show that cutoff before confirmation. The accepted deadline,
freshness, cleaning, and restaurant-failure rules still protect them from an
unserved order: cancellation releases its funding, and the restaurant records
actual consumed waste without revenue. This avoids offering a repeated free
discard action against a stall. Bound future admissions after repeated pre-start
cancellations per principal and hall; never refuse an otherwise eligible free
cancellation or retroactively charge for it. A cancellation racing preparation or
handover uses the scheduled-event/command order and expected versions; a served
course cannot be canceled or refunded through this command. Disconnect is not a
cancellation. Visitor-initiated pre-start cancellation has no competitive
reputation effect; simulated patience failures retain their ordinary treatment.

Turning away a diner before accepting an order is missed demand, not automatically a reputational offense. Accepting work and then failing to deliver can reduce satisfaction. Completed service is scored on quality, actual wait versus expectation, and value. The owner can inspect the main reason for a weak review.

Each diner visit permits at most one main, one optional drink selected alongside
that main, and one optional dessert after main service, all from the same stall.
Each component has a stable order ID, bound price, ingredient/funding commitments,
and settlement under a shared `visit_id`; drink and dessert reference the main.
The initial main and optional drink form one tray, with atomic acceptance and
handover under the drink rules below. Dessert remains a separately accepted and
settled later course. The visit pins its original principal/source, restaurant/
stall, simulated budget, and scoring-policy version. Shared baskets, refills,
standalone drinks, and multi-stall meals remain later features. Client movement
never creates orders or determines revenue.

### Drinks with the main

Each cuisine has one proposed **non-alcoholic drink** in the recipe roster.
Offering it is optional. Proposed progression makes drink and dessert unlocks
independent cash purchases with disclosed equipment requirements; neither
requires learning the other or both savory alternatives first. No drink stock,
employee, station, or extra grant appears simply because the recipe is unlocked.

A drink is an optional same-stall add-on in the main checkout, not a separate
arrival, meal, or later upsell window. Select at most one with the initial main;
after acceptance, no drink can be added or replaced within that visit. Viewing
a menu or declining/unavailable drink carries no penalty. Simulated diners
choose a stall/main through the existing main-only appeal model, then make one
seeded drink choice using thirst/preference, price, full-tray wait, remaining
visit budget, and dietary compatibility. Drinks do not add entry-choice weight
or another variety bonus. If no feasible drink fits, simulated diners can order
the main alone. Human checkout defaults to no drink; diners explicitly select
and confirm all requested items and their combined price; a stale/unavailable requested drink rejects the whole checkout
without silently accepting a main or dropping an item.

Accept the main and selected drink **atomically as one tray**. Consolidate
ingredient needs across both components and check shared stock/storage claims,
jobs/stations, one queue place, funding, dietary requirements, and the combined
carbohydrate amount before reserving either. Separate line-item IDs/prices and
funding slices remain auditable, but the tray binds one maximum service deadline
and one counter-selection/handover. Both components must be ready and fresh at
handover; service settles both payments and served carbohydrate amounts in the
same batch. The main counts once for meals, invitation activity, awards, and a
helper-selected completed task. Drink work uses real finite staff/equipment
capacity; a shared tray does not make preparation free.

Schedule drink preparation to respect its holding lifetime while the main is
being made. Neither component may bypass normal work or freshness rules. If a
component becomes infeasible, expires, or the tray misses its deadline, cancel
the whole unserved tray: release unused stock/funding/carbohydrate commitments,
record actually consumed components as waste once, and collect no revenue.
Voluntary cancellation is available only before preparation of either component
starts and cancels the whole tray. An accepted drink slot never reopens. At
03:00, cancel any unserved tray under the existing cleaning exemption; no drink
is delivered alone or carried into reopening. A main-only tray follows the
ordinary main-order rules.

The main, drink, and later dessert share one visit budget and dietary/carbohydrate
limits. Count milk, sugar/syrup, fruit, and all other drink ingredients from the
resolved bill; a drink being unsweetened does not automatically make it
carbohydrate-free or suitable for a particular profile. After tray service,
dessert eligibility uses what remains. A failed tray grants no dessert offer.
Already served items retain their payments if a later dessert fails. Reports
separate drink revenue, consumed cost/waste, attachment rate, and tray delays.
Cash, inventory, and work-in-progress accounting uses actual component costs.

Drink recipes use the ordinary order-bound preparation/finishing pipeline, with
positive brewing/mixing/assembly durations and explicit finite equipment claims.
Bought roasted tea/coffee, concentrates, potable water, ice, milk/yogurt,
sweeteners, and cups where modeled are costed stock, not free unlimited inputs.
Different tea leaves, coffee preparations, purple corn, barley, hibiscus,
ginger, mint, and panela have distinct products or approved pantry definitions
where required. Long real-world soaking/brewing/chilling is compressed into
versioned work or uses paid prepared bases; no overnight batch production or
customer production during cleaning is introduced. Recipe feasibility,
substitutes, nutrition facts, and equipment costs must validate for all twenty-five
drink recipes. These are cultural inspirations, including shared traditions;
specific preparations, sweetness, serving temperatures, prices, and work remain
proposed content.

The proposed drink roster spans cultured dairy (lassi/doogh), brewed leaf/grain
teas, several coffee preparations, citrus/herb drinks, and purple-corn, hibiscus,
ginger, panela, strawberry, greenthread, prairie mint, and nettle drinks. Similar
ingredients deliberately link cuisines through the wholesale market, while
portions, milk/sugar, equipment, work, and holding lifetimes distinguish their
operating costs. No drink grants a special
health, speed, or staff-performance effect.

### Dessert offers and visit outcomes

A served main unlocks one optional dessert from that same stall, provided the stall still accepts customer orders and its dessert recipe is unlocked, offered, staffed, affordable, reservable, compatible with the visit's dietary requirements and remaining carbohydrate allowance, and expected to finish before the current closure/deadline. A canceled main never grants dessert eligibility. If no eligible dessert can be offered when the main tray is served, finalize the visit with its served main and optional drink immediately. Human diners explicitly accept the dessert's price, resolved ingredients, and maximum service deadline; a main order never authorizes an automatic dessert charge. Simulated diners make one seeded choice after main service using remaining visit budget, appetite, expected quality/value, and wait. For simulated diners, main, drink, and dessert together cannot exceed the original visit budget. Human orders use the current shared dining-wallet balance and ordinary funding reservations. Dessert acceptance uses ordinary queue admission and does not jump ahead of other accepted work.

Proposed human choice time is up to 30 available-service seconds after main service, capped at stall closure or 03:00 cleaning. During this interval the visitor may decline or submit an eligible dessert order; no stock or wallet credit is reserved just for displaying the offer. Acceptance atomically checks canonical principal, visit/main/original restaurant-and-stall identity, current recipe/price, capacity/funding, and an unused dessert slot. At most one dessert order may be accepted per visit, including across sessions; canceling it does not reopen the slot. A rejected submission leaves the slot unused while the original choice window remains open. Main failure, dessert decline, or an unused-offer timeout finalizes the visit. Acceptance ends the choice timer; the dessert then has its own service deadline. Closure withdraws an unaccepted offer and finalizes that main-with-optional-drink visit. An already accepted dessert instead follows the same bounded finish/cancel rules as other orders, with the hard 03:00 cutoff preserved; finalize its visit only after that course settles.

An already served main/drink tray keeps its revenue and outcome if dessert is declined, unavailable, canceled, or unaffordable. Course payments settle separately; a failed dessert never refunds a successful main. Guest allowance issuance remains tied to the existing hall/profile issuance rules, not to the number of courses. Dessert reserves actual remaining allowance/earned-credit slices and creates no new promotional grant, diner, or helper wage bounty. Reconnect recovers the same visit, choice deadline, and accepted course rather than creating another dessert opportunity; disconnected visitors are never automatically charged. No choice timer advances during platform downtime.

Finalize one recognition outcome per visit, after the optional course is resolved. Score courses using the existing quality, wait, value, and failure rules; proposed aggregation weights main:drink:dessert as 4:1:2, normalized over accepted components to one bounded visit score. Without a drink, the existing main:dessert ratio remains 2:1; without either optional item, use the main score alone. There is no penalty for declining or unavailable optional items. A failed accepted dessert affects its course component. A dessert canceled solely by scheduled cleaning is omitted from the visit score, retaining the served tray score and the existing cutoff exemption; actual consumed-food waste still appears in finance. A failed main finalizes its ordinary failure outcome without a dessert, except an exempt scheduled-cleaning cancellation finalizes with that reason and no competitive score. Record finalization once, including explicit component weights and reasons.

Only simulated visits contribute competitive reputation/awards, as before. Completed-meal statistics and invitation activity count served mains once, and never count drink or dessert as another meal. Award scoring uses finalized visit outcomes available in the review period, and a qualifying visit must have a served main; each visit contributes at most once. Record the review cut and finalized-outcome period so late finalization cannot rewrite an already awarded result. Reports distinguish main, drink, and dessert sales, separate optional-item attachment rates, component costs/waste, and final visit satisfaction. Offer timeouts are departures after a served main, not failed orders.

### Customer accounting invariant

Every arrival is accounted for exactly once as an accepted main-purchase decision or a departure without purchase. Optional drink and dessert belong to that same visit and never create another arrival or completed-main count. Every accepted course order ultimately completes or cancels, and every visit finalizes once. Rounded independent restaurant shares must never create or destroy diners.

## 8. Competing for supplies

### Market structure

Each hall has its own wholesale market, finite ingredient stock, published prices, and a replenishment schedule. Launching another hall later must not silently combine its demand or inventory with the public hall.

Ingredients have base prices, target stock, replenishment quantities, storage requirements, and shelf lives. Scarcity raises prices within configured bounds; replenishment reduces scarcity. Announced supplier events may change future deliveries, giving players time to react. The first release has purchases from wholesalers; player-to-player trading, routine commodity resale, futures, and loans are outside scope. Explicit discounted asset liquidation during recovery or lease surrender is a separate exception, not a wholesale resale market.

At midnight, wholesale stock is topped up toward the target set by the previous midnight's business activity forecast. Each ingredient has a baseline stock cap at the forecast floor. The cap grows in proportion to the number of open restaurants above that floor. Each restaurant with an open stall counts once, including NPC restaurants and restaurants whose kitchens are out of stock. Opening a stall between deliveries adds no stock. If stock already exceeds the new cap, it stays in the market and the delivery adds none of that ingredient. Common ingredients link cuisines economically, while specialty ingredients provide different shortage risks.

**Stock size (proposed tuning).** Target stock is set per business equivalent and the cap is four times the target. A hall runs on the first column until the [recorded rule change](ARCHITECTURE.md#the-recorded-rule-change) is applied; a new hall also starts on it. Raising arrivals alone mostly adds diners who find nothing available, so the market is sized with them.

| Value | Current | Chosen (proposed, not applied) |
| --- | --- | --- |
| Target stock per equivalent, per product, in the product's own unit (grams, millilitres or units) | The larger of a base quantity (400 by default; nine named staples have their own, from 100 for cilantro to 5,000 ml for filtered water) and six times the quantity the starter mains' recipe lines use | The larger of the current target and 100 times the largest quantity any recipe line uses of the product (a substitute at its converted quantity, rounded up); no product's target falls |
| Replenishment cap | 4 times the target | 4 times the target |

Two examples, per business equivalent: frozen salmon, which substitutes for salmon at one gram per gram, goes from 400 g to 14,500 g (the largest recipe line uses 145 g of salmon), a rise of about 36 times; long rice, a staple, goes from 1,200 g to 5,500 g (the largest line uses 55 g). 257 of the 274 products rise.

Applying the change adds stock in proportion to each raised target at that moment, so published prices do not jump. The new targets and the higher arrival rate take effect at the next game midnight. The [report](superpowers/reports/2026-11-15-more-real-customers.md#the-chosen-values) lists examples and how the size of 100 portions was chosen. That size leaves nothing scarce on any measured day, which is a choice the owner may revisit.

### Purchasing and clearing

Proposed purchase orders clear in ten-real-second batches. Manual orders and automatic restock policies enter the same clearing mechanism. A submitted request is visibly pending until it receives a final fill or rejection; submitting is not the same as purchasing.

1. The batch uses committed market stock and a single published unit price per ingredient. That price is computed from scarcity before allocating the batch, with a positive minimum and finite maximum.
2. The server consolidates requests per restaurant and ingredient. It validates positive bounded quantities, storage room, current cash, remaining daily budget, and the buyer's maximum unit price.
3. Before allocation, reserve each restaurant's available purchasing budget and shared storage across its requests in its configured ingredient priority, with a stable default order. This produces funded, capacity-backed quantities across all ingredients; different restaurants may have different priorities. Unused reservations are released when the batch finishes.
4. When eligible demand exceeds stock, allocate proportionally among restaurant requests, using integer largest remainders and a rotating deterministic tie-break. Partial fills are permitted and explained.
5. Cash debit for actual filled quantities, market stock reduction, inventory acquisition, reservation release, and the fill receipt commit atomically. A failed commit performs none of them. Partial fills cannot overspend cash or storage already reserved for another ingredient.
6. The next batch's published price reflects remaining stock and any intervening replenishment. Unfilled quantities expire; a player or restock policy may submit another request.

Small batches reduce the benefit of winning a millisecond race to buy supplies. Fixed physical storage, purchasing budgets, and one consolidated request prevent one business from gaining additional allocation by splitting a purchase across its stalls or sending duplicate requests. Rate limits still apply.

The initial scarcity curve may use a clamped stock-ratio function. The displayed price, clearing price, rounding rules, and receipts must agree. Currency is stored in integer smallest units; client-supplied prices are willingness-to-pay limits, never authoritative costs.

### What is public about purchases

**Owner decision (2026-11-13):** other owners, human and computer-run, are seen shopping, so competition for supplies is visible. The owner accepted that an attentive player can infer a rival's menu plans from what they buy. The rest of this section is the designer's call. Spec: [Project 5](superpowers/specs/2026-11-13-livelier-hall-design.md#project-5-supply-market).

Until now the public view carried no orders at all. It now carries, for the newest two clearings that settled a request and for each restaurant that had a purchase fill in one of them, two things and nothing else:

- the product IDs that filled; and
- one of three cart sizes: small, medium or large.

Each trip also carries the clearing's sequence number, so a client draws it once; it carries no time.

Everything else about a purchase stays private to the restaurant that made it: quantities, costs, prices paid, price limits, pending requests, unfilled amounts and the reasons for them. Only the owner sees their own pending requests and the outcome of each recent request (filled, partly filled with the shortfall and its reason, or rejected with the reason). Human and computer-run owners are treated alike, an order placed from a phone counts the same as one placed from the market, and the owner's own purchases are shown to others the same way as anyone's. A restaurant whose request did not fill at all in a clearing appears in no one's view as a shopper. Nobody's position is tracked: a trip is drawn from a fill the server committed, never from a request or from where someone was looking.

Nothing here is a rule. No event, command, catalog version or stored state was added; the recent clearings are a short-lived read model of committed events. After a server restart that read model starts empty, so an outcome settled just before the restart is shown to its owner as settled, with a pointer to their stock, and rivals' recent trips start from nothing. See the [architecture](ARCHITECTURE.md#the-supply-market-view) for where each field lives.

**Proposed defaults (tuning values, not validated):**

- The cart size of a trip is its filled units divided by each product's crate size, summed and rounded up once. One to three crates is small, four to nine is medium, ten or more is large.
- The last six clearings that settled at least one request are kept for the owner's own outcomes, about a minute of real time at the ten-second clearing; the public view carries trips from the newest two of them.
- A product's crate holds about ten servings of the recipe line that uses the most of it (a substitute at its converted quantity), rounded up to 1, 2 or 5 times a power of ten. The server sends it with the price, so one definition serves the picture, the list and the cart.

### Inventory and waste

Stock belongs to the restaurant's shared warehouse. Locations reserve from this common source, which creates expansion efficiencies and genuine competition for limited internal stock.

Warehouse capacity is a business-level asset; opening another stall does not grant free storage. Selling or replacing storage cannot leave current stock/reservations above capacity: require explicit disposal or an atomic capacity-safe plan first. Dormancy retains stored assets and stock-aging obligations, not permission to run replenishment without an active trading business.

Inventory is tracked in batches with quantity, acquisition cost, expiry time, and reserved quantity. Use the earliest-expiring eligible batch of the selected ingredient first. Reserved stock still ages; if it expires before preparation, replace its claims atomically from fresh available stock of the same bound ingredient only if the full resolved ingredient bill can still be satisfied, otherwise cancel the order with a clear reason. An accepted order cannot silently switch to a substitute or back to its primary ingredient. Spoiled/discarded units cannot be consumed or sold. Each unit's spoilage and cost write-off occurs once; canceling an unstarted order does not write off its already-spoiled batch a second time.

The inventory UI shows available, reserved, expiring, and spoiled quantities separately. Stock forecasts include expected open hours, accepted orders, menu mix, and current staffing. Closing can prevent future sales but does not protect ingredients from spoilage.

## 9. Cuisines, recipes, and equipment

All twenty-five confirmed cuisines are available as starting choices in the first playable release. Each has three savory recipes, one dessert, and one drink, for an initial catalog of 125 recipes (75 savory, 25 desserts, and 25 drinks). Proposed progression is one savory starter available initially, with the other two savory recipes, dessert, and drink independently unlockable using business cash and disclosed equipment requirements. Mughlai/Punjabi is one combined starter category; Tamil, Sichuan, and Cantonese are separate choices. European is one broad mixed-menu category, with its specific regional dish mix proposed below. The cuisine roster, three-savory-plus-one-dessert-plus-one-drink count, optional drink alongside the main, and optional same-stall dessert after a main are owner-confirmed; dish selections and operational balance below remain proposals unless explicitly selected by the owner.

The following roster is proposed. Names are culinary inspirations; game ingredient quantities and production stages deliberately simplify real cooking. Content review should check names, descriptions, and art before publication.

The versioned launch catalog compiles the [menu definitions](../server/priv/content/launch_menus.json)
and [ingredient definitions](../server/priv/content/launch_products.json) with
the existing slice recipes. The bilingual labels in those definitions are
shared with the client. Proposed launch tuning allows three stalls per
venture, uses one real minute for expansion and refit setup, and keeps paid
equipment at its installed stall until it is salvaged or stored.

| Cuisine | Savory starter | Other savory recipes | Dessert | Drink | Primary operational identity |
| --- | --- | --- | --- | --- | --- |
| Mughlai/Punjabi | Chole with rice | Butter chicken with naan; paneer tikka with naan | Gulab jamun | Sweet lassi | Affordable chickpea base; curry and tandoor progression; shared sauces, dairy/flatbread costs, and vegetarian/chicken alternatives. |
| Tamil | Idli with sambar | Masala dosa; vegetable uttapam | Paal payasam | Filter coffee | Purchased ready-to-cook rice-lentil batter and lentils; steamer starter with griddle progression; batter freshness, potatoes, vegetables, and regional pantry ingredients. |
| Japanese | Chicken teriyaki rice | Vegetable udon; salmon rice bowl | Dorayaki | Sencha | Rice and noodle flexibility; perishable premium fish option. |
| Sichuan | Vegetarian mapo tofu with rice | Kung pao chicken with rice; vegetarian dry-fried green beans with rice | Brown-sugar bingfen | Jasmine tea | Wok throughput and short ready-food holding windows; tofu/chicken/vegetable flexibility; Sichuan pantry, peppercorn, and chili-bean-paste supply exposure. |
| Cantonese | Mushroom cheung fun | White-cut chicken with ginger-scallion sauce and rice; char siu pork with rice | Egg tart | Hong Kong-style milk tea | Rice-roll steaming at entry, poaching/roasting progression; mushroom/chicken/pork supply choices, timing, and freshness-sensitive quality. |
| Mexican | Bean tacos | Chicken tacos; vegetable quesadilla | Arroz con leche | Rice-cinnamon horchata | Fast griddle or assembly work; tortillas; different protein costs. |
| Levantine | Falafel wrap | Chicken shawarma wrap; mujaddara | Knafeh | Mint lemonade (limonana) | Chickpeas, lentils, flatbread, and chicken; affordable vegetarian dishes alongside roast-meat wraps, with hot cheese-and-pastry dessert finishing and dairy-cost exposure. |
| Persian | Vegetarian adas polo | Ash reshteh; zereshk polo ba morgh | Sholeh zard | Doogh | Affordable lentil/rice starter; herb-and-noodle soup and saffron/barberry chicken-rice progression; rice timing, herb freshness, kashk, and specialty pantry costs. |
| Thai | Basil chicken rice | Tofu pad Thai; green curry | Mango sticky rice | Thai iced tea | Rice/noodle alternatives; sauces and coconut ingredients. |
| Berber | Vegetable couscous | Chicken tagine with preserved lemon and bread; vegetarian tikourbabine | Baghrir with honey | Mint tea (atay) | Selected Amazigh regional traditions: couscous steaming, tagine simmering, Kabyle semolina-dumpling finishing, and semolina pancakes; grains, vegetables, herbs, olive oil, and preserved-lemon supply. |
| Ethiopian | Shiro with injera | Misir wot with injera; doro wat with injera | Sweet himbasha | Buna (black coffee) | Chickpea-flour and lentil stews before a chicken/egg alternative; injera freshness and berbere pantry exposure; timed simmering and assembly. |
| Peruvian | Papa a la huancaína | Ají de gallina with rice; lomo saltado with rice and potatoes | Picarones | Chicha morada | Potato/ají/dairy starter; chicken sauce and high-heat beef progression; potato, rice, and protein cost tradeoffs. |
| Turkish | Mercimek çorbası with bread | Spinach-and-cheese gözleme; köfte with bulgur | Halvah (tahin helvası) | Turkish black tea (çay) | Lentil-soup entry, flatbread griddle and meat-grill progression; flour, dairy, lentils, bulgur, minced meat, and sesame/tahini supply choices. |
| Vietnamese | Tofu bánh mì | Chicken phở; bún chả | Chè chuối | Cà phê sữa đá | Bread/assembly entry, broth heating and pork grilling progression; fresh herbs, rice noodles, and bread freshness. |
| Javanese | Vegetarian pecel with rice | Vegetable nasi goreng; chicken satay with rice | Klepon | Wedang jahe | Vegetable/rice and peanut-sauce starter; rice stir-fry and skewer grilling alternatives; peanut, sweet-soy, and protein supply exposure. |
| Korean | Vegetable bibimbap | Vegetable japchae; beef bulgogi with rice | Brown-sugar hotteok | Boricha (barley tea) | Multi-component vegetable/rice assembly; glass-noodle stir-fry and marinated beef grilling; condiment, produce, and beef-cost tradeoffs. |
| European | Tomato pasta | Ratatouille with bread; chicken schnitzel with potatoes | Apple crumble | Espresso | A proposed mixed European menu: pasta boiling, vegetable simmering, and breaded pan-frying; wheat, tomato, herbs, potatoes, and chicken demand. |
| Brazilian | Vegetarian arroz com feijão | Frango com quiabo with rice; moqueca de peixe with rice | Brigadeiro | Cafezinho | Affordable rice/black-bean base; chicken/okra and fish-stew alternatives; shared legumes, okra, coconut/palm-oil pantry ingredients, and fish freshness exposure. |
| Yoruba | Vegetarian ewa riro with plantain | Vegetarian moi moi with rice; efo riro with fish and amala | Puff-puff | Zobo (hibiscus drink) | Bean-stew entry, steamed cowpea pudding, leafy-green/fish stew with yam-flour amala, and fried sweet dough; cowpeas, palm oil, leafy greens, yam flour, plantain, and fish supply. |
| Colombian | Arepa con queso | Patacones with hogao and beans; ajiaco | Obleas con arequipe | Aguapanela with lime | Cornmeal/cheese griddle entry; green-plantain frying and chicken/potato soup alternatives; cornmeal, plantain ripeness, potatoes, dairy, and herb supply. |
| Haudenosaunee | Three Sisters soup (corn, beans, and squash) | Oneida white-corn soup with pork<br>Boiled corn-and-bean bread with roasted squash | Berry corn mush with maple syrup | Strawberry drink | Economical soup starter and a pork-based alternative. Hulled white corn and corn flour have different preparation and storage costs. |
| Diné (Navajo) | Lamb and steamed-corn stew | Blue-corn dumpling stew<br>Blue-corn griddle cakes with roasted squash | Red sumac berry pudding | Greenthread tea | Purchased steamed corn keeps the starter compatible with order-bound work. Blue cornmeal links simmered dumplings and griddle cakes. Lamb, sumac berries, and greenthread are distinct supply lines. |
| Lakota | Bison and prairie-turnip stew | Cedar-braised bison<br>Roasted squash with wild onions | Wojapi (berry sauce served as a small dessert portion) | Wild prairie mint tea | Stew and braise share bison supply. The squash alternative gives a lower-cost menu when bison is scarce. Prairie turnips and berries have separate supply and holding rules. |
| Coast Salish | Roasted salmon | Steamed clams with kelp<br>Halibut and seaweed broth | Huckleberry compote | Nettle tea | Salmon roasting, shellfish steaming, and broth finishing use different station capacity. Distinct finfish, shellfish, and seaweed stocks shape spoilage and shortage risk. |
| Māori | Pork-and-pūhā boil-up with kūmara and doughboys | Hāngī-style chicken with kūmara and cabbage<br>Green-lipped mussel fritters | Steamed golden-syrup pudding | Kawakawa tea | Simmered starter, steamed chicken/pudding, and griddle-finished fritters. Pūhā and mussels have finite chilled/frozen supply; kawakawa remains a distinct food-grade herb. |

These Indigenous menus draw on specific published examples. Credit the
named communities and recipe authors in content notes. Describe the dishes as
selected examples of living food traditions and identify the proposed game
adaptations, including the dessert portions and course placement. Retain each
cuisine's own content ID, ingredient distinctions, and translations. Use public
culinary sources for the food and presentation, and keep ceremonial practices
outside the restaurant simulation.

- Haudenosaunee (`haudenosaunee`) draws on Oneida sources for the Three Sisters,
  white-corn preparations, berry corn mush, and strawberry drink. The starter
  soup and squash pairing are game menu proposals. [Oneida food sovereignty](https://oneida-nsn.gov/pressroom/educational-campaigns/) · [Oneida Nation Cannery menu](https://oneida-nsn.gov/blog/event/santa-to-go/) · [Oneida community corn bread account](https://oneida-nsn.gov/wp-content/uploads/2016/03/August-4-2016.pdf) · [Oneida corn soup](https://oneida-nsn.gov/wp-content/uploads/2025/08/Drums-Sep-2025.pdf).
- Diné (Navajo) (`dine`) draws on published Diné steamed-corn stew, dumpling
  stew, and blue-corn griddle preparations. The squash pairing is a game menu
  proposal. [Diné food curriculum by Denisa Smiley](https://in.nau.edu/wp-content/uploads/sites/101/2026/01/DenisaSmiley2025.pdf) · [Navajo Nation food accounts](https://oscad.navajo-nsn.gov/Portals/0/FILES/Books-Downloads/Ama%20Sani%20doo%20Achei%20Baahane_edit2.pdf) · [Fort Defiance Indian Hospital Board sumac berry pudding](https://www.fdihb.org/resources/sumac-berry-pudding) · [New Mexico Historic Sites on Navajo tea](https://nmhistoricsites.org/bosque-redondo/site-audio-tour/nature-trail-audio-stop-14).
- Lakota (`lakota`) draws on bison and prairie-turnip soup, Oglala Lakota chef
  Sean Sherman's cedar-braised bison, wojapi, and wild prairie mint tea. The
  squash plate and dessert serving are game menu proposals. [South Dakota Native Tourism Alliance](https://sdnativetourismalliance.org/individual-travel/agritourism-culinary-experiences/) · [Sean Sherman's cookbook](https://www.upress.umn.edu/9781452967431/the-sioux-chefs-indigenous-kitchen/) · [Matte Wilson's meal and wild prairie mint tea](https://watch.weta.org/video/the-lakota-nation-a-story-of-empowerment-8ZIftc/).
- Coast Salish (`coast_salish`) draws on documented salmon, clams, halibut,
  edible seaweeds, berries, and nettles from selected Coast Salish foodways.
  The broth, clam pairing, and compote are game menu proposals. [Burke Museum Coast Salish food list](https://www.burkemuseum.org/news/traditional-coast-salish-foods-list) · [Tulalip Tribes on huckleberries](https://tulalipnews.com/2025/08/13/huckleberry-harvest/) · [Tulalip Tribes on nettles](https://tulalipnews.com/2014/03/19/nettle-the-nutritional-nuisance-hibulb-rediscovery-program-begins-annual-spring-harvest-of-traditional-superfood/).

- Māori (`maori`) adds selected kai from Aotearoa/New Zealand. The boil-up
  combines pork, pūhā, kūmara and flour dumplings; the hāngī-style plate and
  pudding use the game's ordinary steam station as an explicit food-hall
  adaptation, without simulating an earth oven, geothermal cooking or ceremony.
  Mussel fritters and kawakawa tea complete the menu. Portion sizes, prices,
  carbohydrate metadata and substitutions are proposed game balance choices.
  [Te Ara on boil-up](https://teara.govt.nz/en/maori-foods-kai-maori/page-4) ·
  [Whakarewarewa food and steamed pudding](https://whakarewarewa.com/experiences-traditional-food/) ·
  [Edmonds mussel fritters](https://edmondscooking.co.nz/recipes/fritters/mussel-fritters-2) ·
  [Te Ara on kawakawa tea](https://teara.govt.nz/en/interactive/40270/kawakawa-tea).

The ingredient catalog should distinguish hulled white corn, blue cornmeal,
prepared steamed corn, and the other named corn products. Model the named fish
and shellfish individually, and use food-grade pantry definitions for herbs and
prepared bases. Preserve signature ingredients in substitutions, with explicit
exceptions where a suitable fallback would change the dish's identity.

Levantine replaces the earlier Lebanese category with a broader regional scope.
Its savory/dessert assortment is falafel wrap, chicken shawarma wrap, mujaddara,
and knafeh; mint lemonade is its proposed drink. The owner-selected dessert is knafeh, replacing the earlier muhallabia proposal.
It remains one cuisine with three savory recipes, one dessert, and one drink, following
the same skill, unlock, preference, and award rules as other categories;
broader scope grants no extra demand or variety bonus.

Proposed knafeh content uses a hot cheese-and-pastry portion with syrup. Its
independent dessert unlock requires a disclosed, purchased compatible hot-dessert
finishing capability; it grants no free station or extra staff. Suitable dessert
cheese, pastry, butter/ghee, and syrup ingredients are costed inventory with
explicit quantities, shelf lives, and approved substitutions. Tune a short
ready-food holding lifetime that still permits the ordinary counter-selection
and handover phases under feasible coverage. Preparation/finishing uses the
existing order-bound pipeline and shared capacity, with no advance tray
production or carryover through cleaning. Exact ingredients, equipment costs,
work durations, and the serving window remain versioned balance proposals.

Javanese replaces the broader Indonesian category. The proposed starter is
vegetarian pecel with rice, replacing gado-gado; vegetable nasi goreng, chicken
satay with rice, and klepon remain the proposed other food recipes; wedang jahe
is its proposed drink. These use authored
Javanese-style preparations and compatible pantry definitions. It remains one
cuisine with three savory recipes, one dessert, and one drink; shared dishes need not be
exclusive to that tradition.

Desserts and drinks are optional menu expansions within each cuisine. They compete for the same cash, shared stock, storage, staff, queue, and station capacity as savory food, with their own full ingredient bills, substitutions, prices, work, and ready-food lifetimes. Adding dessert or drink recipes does not grant another employee, station slot, or free starting inventory. Each optional recipe unlock has no requirement to learn the other or both savory alternatives first; any required equipment/capability is disclosed and purchased normally.

Dessert work uses the existing preparation/finishing pipeline. Recipe content can require griddle/frying, simmering, baking, chilling/setting, or assembly capabilities with explicit positive work durations and finite capacity. A cold dessert is not instant service: bought plain components or bases are paid inventory, and final assembly/finishing still occupies its declared resources before ordinary counter selection/handover. Chilling, if required, uses an explicitly costed compatible finishing/storage capability; its duration and staff-claim policy are versioned. No extra phase may bypass stock aging, ready-food expiry, or the cleaning cutoff. Long real-world processes are compressed to game time under the same rules as savory recipes.

The dessert selections are culinary inspirations, including shared traditions; presenting sweet himbasha as a dessert portion is a game menu choice, not a claim that every cuisine follows the same course sequence. Shared staples such as milk, sugar, rice, flour, eggs, coconut, and fruit create more market competition. Distinct ingredients such as glutinous rice/flour, adzuki paste, bingfen base, cocoa/condensed milk, semolina, tapioca, pandan, wafers/arequipe, saffron, sesame/tahini, and nuts/seeds need their own product or pantry definitions where used. Desserts preserve declared dietary contents and signature identity under substitutions, just like mains.

The starter catalog shares ingredient families such as rice, noodles, chicken, vegetables, beans, tofu, and bread/flatbread. Additional products include dairy/paneer, pork, beef/minced meat, eggs, mushrooms, potatoes, peanuts, couscous, bulgur, pasta, glass noodles, ají, chickpea flour, injera, barberries, kashk, cornmeal, cowpeas, yam flour, semolina, okra, plantains, white fish, and ready-to-cook rice-lentil batter as required by the actual recipe bills. Distinct grains, flours, noodles, and breads retain their own product IDs and yield/storage rules; sharing a broad family does not make them freely interchangeable. Cuisine-specific pantry packs represent detailed seasonings and sauces omitted from the economic model. Use distinct pack definitions when their contents and dietary claims differ; a broad national label does not make two regional packs interchangeable. The proposed Tamil launch recipes buy ready-to-cook batter as ordinary perishable inventory; player-run fermentation and overnight batch cooking are outside this initial catalog. Explicit vegetarian/vegetable variants, including arroz com feijão, ewa riro, moi moi, tikourbabine, adas polo, mapo tofu, dry-fried green beans, tofu bánh mì, vegetarian pecel, vegetable nasi goreng, bibimbap, and japchae, use compatible sauce, stock, and pantry definitions. Removing an animal ingredient from a differently labeled recipe is not a silent substitution. Every cuisine should have at least one relatively inexpensive dish and one meaningful alternative when a major ingredient becomes scarce.

Berber is the selected category name; Amazigh is used as an explanatory alternate name. Its proposed menu draws from multiple North African Amazigh regional traditions, including a Kabyle dish, rather than merely relabeling the earlier national menu. Shared dishes need not be exclusive to that category. Yoruba replaces the earlier Senegalese category with a distinct Yoruba menu and ingredient profile. Tamil narrows the earlier South Indian label while retaining the proposed idli, dosa, uttapam, and paal payasam selections. These are starter assortments, not exhaustive definitions of the respective food traditions.

European's three savory dishes, dessert, and drink form a proposed launch assortment within the owner's broad category, rather than an exhaustive definition of European food. Its skill, recipe unlocks, cuisine awards, and preference weights follow the same single-category rules as other starters. Its breadth grants no extra variety or demand bonus beyond the ordinary bounded menu rule. Recipe and ingredient identifiers permit more specific regional categories to be introduced later through a deliberate content revision.

Supplier-prepared inputs such as injera, bread, fermented batter, broth bases, and preserved condiments may be ordinary purchased inventory with explicit acquisition cost, quantities, shelf life, and dietary contents. Their upstream preparation does not create free work or stock in the restaurant. Long real-world cooking processes are compressed into versioned game work; the launch loop remains order-bound preparation/finishing, with no overnight fermentation or extra production during the hall's 03:00–05:00 cleaning closure.

Starter kits must fully support their starter dish under the common starting-capital and staffing rules. Additional recipe unlocks disclose any new compatible station/equipment costs before purchase: for example a griddle for Tamil alternatives, tandoor capability for paneer tikka, and poaching/roasting capability for Cantonese alternatives. Stations remain the existing preparation/finishing resource model, with compressed game-time work and automatic staff execution. These operational identities guide balance; they are not claims that the real cuisines are limited to these methods or dishes.

Each cuisine has its own stable content ID, recipe unlocks, skill references, preference weights, and applicable recognition. Shared ingredients/equipment can provide efficiencies through the existing rules, while changing a stall's cuisine still requires the normal closed refit. Rebalance customer preference weights over the twenty-five choices within the finite hall arrival pool. When splitting a broad category, apportion its demand weights across the new categories. Every cuisine is eligible for NPC starter selection and has a validated starter kit. Bootstrap uses three NPC restaurants with varied operating profiles and ingredient exposure.

Recipes define their cuisine, unlock, full primary ingredient bill and approved substitute mappings, preparation/finishing stages, station requirements, baseline durations, ready-food holding lifetime, quality modifiers, and suggested price range. Counter-selection/handover timing belongs to the versioned support-position policy and is included in service estimates. Full quantities, yields, freshness, compatible equipment, and a feasible starter roster belong in content data and must validate before enablement. The roster alone is not an executable recipe catalog.

### Ingredient substitutes

Most primary recipe ingredients have one approved direct substitute in the launch catalog. Substitutes offer a lower usual cost, more dependable wholesale supply, or both, in exchange for slightly lower dish quality. Examples to validate in content include premium versus standard rice, fresh versus frozen vegetables, and a premium versus basic pantry blend. These are game balance choices about the specified products, not universal claims about those foods. Some signature ingredients may have no suitable alternative; each exception is explicit. Validate that more than half of the distinct primary ingredient IDs used by launch recipes have a compatible substitute, with useful options in all twenty-five cuisines. Substitute-only products do not themselves need another fallback.

Mappings are recipe-specific approved alternatives, with a positive bounded quantity/yield conversion and quality penalty. A substitute is its own wholesale item with finite stock, scarcity pricing, shelf life, storage use, and acquisition cost; substitution never converts owned stock into free units. Cheaper refers to typical conditions, not a guaranteed price advantage during every shortage. Suppliers can run out of both products. Alternatives must preserve the dish's identity and any published dietary/ingredient claims; changing a meat or dietary category belongs in a separately described recipe rather than a hidden swap. No recursive substitutions or arbitrary ingredient matching.

For each recipe, owners choose **primary only** (default), **prefer primary, allow fallback**, or **prefer substitute** for specified eligible lines. Staff resolve that policy automatically before order acceptance, using the whole bill and shared warehouse availability. Use one selected product per ingredient line in the first release; do not mix primary/substitute quantities within a line. Multiple lines needing the same stock must be consolidated before feasibility/reservation checks. If no complete policy-permitted bill can be reserved, the dish is unavailable. Owners see expected ingredient cost, contribution margin, quality reduction, and available servings for the resulting variant. Restock targets and price ceilings remain explicit per product within the existing shared storage/spending limits; offering a substitute does not authorize purchasing it or reserve both variants. Cost-plus pricing uses replacement costs for the offered variant, while the ledger uses the actual consumed batches.

Menus disclose the possible alternatives and the resolved variant's expected quality. Human diners see the actual selected ingredients and price before confirming; if a stale quote would require a different variant, request reconfirmation. Simulated choice uses the same offered variant's expected quality/value. Acceptance atomically pins its resolved bill, conversions, substitution penalties, and content version with the stock reservations. Later policy edits apply only to new orders. Preparation, freshness, cancellation, waste, and service follow the ordinary pipeline using those actual items and costs.

Proposed initial tuning subtracts three points per substituted recipe line from a normalized 100-point dish-quality score, capped at nine points per dish and clamped to the valid score range. Apply this once alongside skill, freshness, fatigue, and cleanliness; the exact small penalties require playtesting. Lower price or continued availability may offset the quality loss for value seekers, while quality seekers are more sensitive. Disclosed substitutions still affect delivered quality and eligible reputation/awards; disclosure does not erase the penalty. There is no extra arbitrary deception penalty for the agreed variant. Report the quality and cost effects separately so owners can judge whether the saving is worthwhile. Human owners, unattended policies, and NPCs use the same rules.

### Production rules

Every starter stall has a preparation station and a cuisine-appropriate finishing station. Equipment is capacity and capability, not a manual cooking minigame. The player configures assignments and menus; staff choose the next eligible job automatically.

Order flow:

`Accepted and ingredients reserved → waiting for staff/station → preparing → finishing → ready for handover → counter selection → handing over → served`

Cancellation can occur before service. Ingredients are reserved once at acceptance and consumed once when preparation begins. Cancellation before preparation releases unconsumed reservations; cancellation after preparation records the consumed food as waste once. Ready meals have a recipe-defined holding lifetime; expiry, abandonment, or cancellation cannot release consumed raw stock or resell the same meal. Handover requires an available support position and a still-valid meal/order. The server collects the bound menu price only at completed handover, atomically settling visitor funding if applicable. Unserved orders release their spending reservation rather than creating a refund of revenue never collected.

Recipe-defined finishing may contain sequential timed steps, including cooling/setting where specified; all required steps finish before the dish becomes ready. Passive steps retain their station/storage claim while releasing a worker only if the authored claim policy permits it. Each stage has a stable job ID, assigned worker, station, remaining work, and status. Progress depends on staff skill, fatigue, and equipment. Interrupting a worker pauses affected work until coverage resumes; it does not reset progress or create a second copy of the job. Paused work and served food cannot be processed twice.

A baseline dish might require one game minute of preparation and three of finishing, or ten real seconds of kitchen work at normal efficiency. Counter service then occupies the support position for a proposed two-game-minute selection phase and two-game-minute handover: five real seconds each before efficiency modifiers on handover. The selection window has the same fixed duration for automatic and visitor control, so it provides readable input time without adding a visitor-only delay or speed bonus. All stages and queue time appear in estimates. Faster clicking does not bypass work or add another support position.

Quality uses explicit factors such as selected ingredient substitutes, skill, freshness, and fatigue. The first release favors explainable quality penalties over unexplained random burning. Cleanliness is maintained by scheduled support work and affects quality/service outcomes. Equipment wear, fire, detailed utilities, and freeform kitchen construction are later scope.

### Upgrades and unlocks

Initial progression offers recipe learning, faster or parallel equipment, better storage, staff training, and additional stall leases. Unlocks use business cash and clear prerequisites rather than adding an unrelated premium or research currency.

Tradeoffs remain visible: a faster station costs more to buy and operate; a broad menu consumes more inventory variety; longer-lived storage ties up capital; a premium recipe can raise margin but also waste and queue risk. New savory recipes are alternatives rather than universally superior replacements; drinks add an optional tray component and desserts a later course, each with cost and capacity tradeoffs.

Changing cuisine or replacing incompatible equipment requires a closed, settled stall and a disclosed refit cost/duration. Preserve compatible inventory and shared recipe knowledge; incompatible stock remains owned rather than silently disappearing. Training that takes a worker off duty and capacity-changing upgrades revalidate affected coverage, queued work, and storage claims before acceptance. A refitting location keeps its lease and holding fee, and cannot accept diners or helper offers until the refit completes.

## 10. Staff and schedules

Staff members have a role, wage rate, service or cuisine skills, fatigue, and current assignment. The initial roles are cooks and support staff. Support covers counter handover, preparation assistance, and routine stall cleaning during customer-accessible hours according to a simple task policy; this is separate from the automatic hall-wide 03:00–05:00 cleaning. Cuisine skill affects quality; equipment and coverage constrain speed.

Hire from a rotating roster with disclosed wages and skills. The starting package includes enough staff for a proposed twelve-game-hour first service window, with staggered shifts and breaks. The first opening can start immediately outside cleaning when coverage and stock permit; during cleaning, setup continues and opening waits until 05:00. A first window that meets 03:00 is truncated there, with the next permitted staffed window shown explicitly; it does not promise twelve uninterrupted trading hours across cleaning. The UI then suggests a recurring schedule. Longer trading requires its additional coverage and budget, up to the hall's 22 daily customer-accessible hours. A solo owner can run a complete starter restaurant without recruiting another player or performing kitchen actions. A support worker doing preparation, cleaning, or handover occupies one task at a time; forecasts cannot count the same worker as simultaneous coverage for several stages.

The player can assign workers through a roster panel or drag them between owned stalls. Equivalent keyboard and menu actions are required. A worker can have only one assignment at a time. Reassignment respects remaining stage work and shift boundaries; moving a portrait must not duplicate labor.

Fatigue accumulates during work and recovers off duty or during breaks. Moderate fatigue reduces efficiency; severe fatigue reduces quality and triggers an automatic protective break at a disclosed limit. The UI forecasts gaps and warns before a shift plan becomes unsafe. Continuous opening requires actual roster coverage, including breaks.

Wages accrue for scheduled on-duty coverage, including ready standby between tasks, with explicit treatment of accepted work completed during closing. Off-duty time and breaks are unpaid in the initial model. Human and automatic control use the same position rate and coverage rules; visitor pay is not a per-click bounty. Hiring, training, dismissal costs, and wage rates are shown before confirmation. Automatic shift replacement is an optional policy using the owner's roster and limits, not an unbounded permission to hire new staff.

Hired staff can work across their restaurant's stalls. Hired roster members cannot be transferred between unrelated businesses or borrowed from NPCs in the first release. Unlicensed visitor helpers may accept separate shifts at different businesses after ending their current shift; this does not transfer a hired employee or grant staff-poaching powers. A competitive labor market for permanent hires remains later work.

### Visitor helper shifts

Helper work is available only to principals without a restaurant license. Owners cannot accept or control helper shifts at their own or any other stall, including NPC stalls, even between ventures or after bankruptcy. Granting a license through an invitation, seed admission, or application approval ends any active helper shift in the same committed batch, pays the covered interval once, releases remaining payroll and task/selection claims, and returns control to automation. An interrupted shift supplies no new successful-shift proof. Prior earnings and work history remain available on Profile after Work navigation disappears.

Start with one **counter-helper** role. During the counter-selection phase, visitors choose an eligible ready order, match its dish, and submit their choice. At the phase boundary, automatic service selects ready-time FIFO with stable ID tie-breaks; a helper's still-valid choice can prioritize another ready order, for example one near its patience deadline. A stale/expired choice cannot force service and falls back to an eligible automatic choice. The selected handover then takes its normal work duration; a submitted match is not a completed sale. Selection itself occupies the backing support position, so it cannot also clean, prep, or run another counter in parallel. This gives the helper actual agency without a race to beat an instantaneous automatic assignment. A task list and keyboard controls support play without precise 3D movement. Cooking, purchasing, pricing, hiring, and owner finances remain outside this role.

Human owners explicitly enable visitor help for selected support positions and can withdraw it. NPC restaurants may enable offers automatically within the same budgets and staffing rules. Offers show the role, tasks, wage rate, actual maximum duration truncated at the backing worker's break/end, estimated earnings, and the ability to leave early. Proposed initial shifts last five service minutes, or two game hours when continuously available, configurable up to ten service minutes. Later owner reassignment can end the shift early but must pay its covered interval. Tune wages so a short attended shift can reasonably fund a basic meal, while remaining viable for the employer; estimates are not a promise of a full-duration shift.

Each offered position is backed by a hired, scheduled automatic support worker. The visitor temporarily controls that position; the same worker skills, fatigue, work capacity, and existing jobs apply. Accepting a shift does not add another worker or apply an unlimited throughput bonus. Restaurants remain fully playable with automatic staff alone. A visitor can hold one shift, a position can have one active visitor, and a task can have one controller at a time, including across multiple browser windows.

A ready counter item is an initial main tray (including its drink if ordered)
or a later dessert. Helper matching shows every tray component and targets the
shared handover, not a standalone drink. A main/drink tray produces one completed
helper-selected task and one wage interval under the ordinary control rules.

#### Milestone 5 counter-helper interactions

Work shows approaching trays with estimated readiness and distinguishes them
from selectable ready trays. For each ready tray, show its components, elapsed
wait, and time until its current serve-by or freshness limit, whichever comes
first. Identify the automatic FIFO choice so a helper can decide whether
another ready tray is more urgent. Use anonymous tray identifiers. After
selection, show which tray is going out, actual handover progress, and the
result. The same task list and choices are available without moving an avatar.

Add one optional quiet-period task, **stage pickup supplies**. An idle counter
can prepare one reusable pickup place for a tray that is still in the kitchen.
Staging uses the same support worker and moves a small, disclosed part of the
ordinary handover setup earlier. The next handover consumes the staged place
once. The counter can hold one staged place, and staging adds neither kitchen
capacity nor another staff assignment. Starting the task requires an
unprepared counter and no eligible ready tray or handover. If a tray becomes
ready during staging, the helper can finish the short setup or yield to
service. Yielding discards incomplete setup and immediately allows the normal
selection phase. Yield automatically if continuing would conflict with a known
service deadline. Completion can save at most the setup time already worked.
If valid staging completion and tray readiness coincide, apply the completion
before opening the selection phase. Expiry and cleaning retain their ordinary
precedence. Automation can stage and serve under the same rules and yields to
ready work when it interrupts staging. A stale choice, disconnect, or expiring
task hands control back through the existing fallback. Closure and cleaning
invalidate staging and its unused setup credit.

Start with two real seconds of staging and up to two seconds saved on the
next handover. Keep both values provisional until playtesting. Quiet
shifts show whether work is expected and keep normal paid standby available.
Staging can appear separately in work history. It earns the ordinary on-duty
wage and does not count as the completed handover required for license
eligibility.

An offer is an expiring quote, not a payroll lock merely because somebody viewed it. Acceptance atomically rechecks the position/shift window, wage terms, owner opt-in, and available funds, then commits the maximum payroll for the accepted period. Reuse an existing reservation for that same position/time instead of reserving twice. Visitor-controlled on-duty coverage, including connected ready standby, earns dining credit at the posted rate; automatic coverage uses the ordinary wage sink. The visitor's limit ends at a scheduled worker break/end or earlier business stop even if the nominal offer was longer. The restaurant is never charged both recipients for the same position/time interval. Posted rates stay within the role's wage rules.

Visitor-payroll transfers additionally require bounded authorization per stable employer owner/operator and per hall in unaccelerated service-hour windows. Reserve the maximum transfer allowance in every window the shift spans before accepting it, settle actual eligible coverage against those reservations, and release unearned portions. These are transfer limits, not another source of money. They survive business failure, replacement, and guest credential changes; NPC replacements retain their operator identity. Fixed values must be supplied by release content. They bound startup-grant cycling into guest credit without imposing a restart cooldown, refusing already earned pay, or relying on anonymous cookies as proof of a unique human. Normal payroll continues automatically when no visitor transfer capacity is available; no new visitor shift is promised in that case.

The server records covered time and control boundaries, settles partial shifts, and carries fractional-unit accrual without rounding each click, timer step, or handover into extra pay. Business payroll debit, visitor credit, transfer-limit consumption, and the unique settlement receipt commit atomically. Funded earned wages settle before distress/bankruptcy releases remaining commitments; they are not forfeited when the employer fails. Unearned future payroll and transfer authorization are released when the shift ends. Dining credit cannot be deposited as restaurant capital, transferred to another visitor, or multiplied by creating another guest session. Dining purchases using wages follow the ordinary visitor order and recognition rules.

Guests receive a stable server-issued profile/credential for earnings and work history, retained across normal reconnects. Optional verified-email recovery restores that profile, including licensing eligibility and application status; it does not itself grant an owner license. A later invitation or approved license application promotes the same guest identity without duplicating the wallet, seed grants, or tree ancestry. Dining credit stays separate from any new business's capital. As with other unlinked identities, losing the only guest credential loses access to its saved credit and application; knowing an applicant's public name cannot recover it.

Leaving, losing the connection, reaching the shift limit, a backing-worker break/end, or failing to choose by the selection deadline ends the visitor shift and hands control back to automation. Fifteen service seconds is the upper actionable-idle limit for longer tasks; this initial role normally falls back at its earlier five-service-second selection boundary. No available work leaves a connected helper on paid standby rather than an idle failure. Automatic selection/handover retains already elapsed phase work and the normal timeline. There is no special input-failure damage penalty; different valid prioritization choices can still change which diners are served first.

Control uses two explicit levels: a generation on the position's helper lease and a generation on each exclusive task claim. Task messages include both. Handover/reassignment invalidates the relevant generations while preserving completed work and its remaining duration; late messages cannot complete, undo, or collect pay for another controller's work. The same event batch settles the old payable interval, releases unused reservations, and records automatic control. Reconnect can recover wages/history but cannot resurrect an ended shift; a new shift needs fresh acceptance.

The owner can end a shift or reassign its backing worker, settling earned wages and handing over or pausing work under the usual staffing rules. Stall closure, safety stop, NPC retirement, distress, and bankruptcy end affected visitor shifts and release unused commitments. Fallback cannot reopen a closed restaurant or override a safety stop. A helper's presence does not keep an absent owner's stall open or count as another human owner for NPC retirement.

Successful shifts also unlock the optional [restaurant-license application](#restaurant-licenses-and-applications). Work history and the completion proof are server-owned; payroll remains payable regardless of eligibility or the review outcome. Detailed cooking minigames, specialist visitor roles, tips, visitor-to-visitor transfers, and a transferable labor market are later scope.

## 11. Finance and viable businesses

### Accounts and costs

Cash belongs to the restaurant, not the owner's lifetime profile. The business ledger records sales, ingredient purchases, consumed ingredient cost, waste, wages, rent and holding fees, operating costs, equipment, unlocks, and lease setup costs. All currency is virtual.

Time-based costs accrue proportionally to elapsed game time in the relevant state. Opening briefly does not incur an unexplained full-day rent charge, and repeated opening/closing cannot erase costs already accrued. Closing-state work still incurs its actual labor and operating costs; the holding rate begins after work has settled.

Financial reporting distinguishes:

- **Contribution per dish:** sale price less consumed ingredient cost and directly variable service cost.
- **Operating profit:** sales less ingredient cost of served meals, waste/write-offs, wages, lease costs, and operating overhead over the period.
- **Cash flow:** actual receipts less cash payments, including stock purchases and capital expenditure.
- **Available cash:** cash remaining after committed obligations and configured reserves, available for discretionary purchases.

Buying ingredients reduces cash and increases raw-inventory value. Starting preparation transfers the consumed cost into work-in-progress/ready-food value, rather than immediately expensing it. Service moves that cost to cost of sales; cancellation/expiry after preparation moves it to waste instead. Raw-stock spoilage writes off raw inventory directly. The same value cannot appear in both served cost and waste, or be expensed on purchase and again on use. Wage/cost accrual recognizes its expense once; later payment settles the liability/reservation without another expense. Capital purchases are shown separately from operating profit in the initial management report; this is a game report rather than a real accounting product.

### Illustrative starting balance

These are tuning examples in virtual dollars, not fixed release prices:

| Starter expenditure | Amount |
| --- | ---: |
| Initial restaurant capital | $5,000 |
| First lease, starter equipment, and setup | -$2,200 |
| Initial usable stock | -$400 |
| Remaining cash before trading | $2,400 |

An illustrative 24-game-hour day with 22 trading hours and two cleaning hours in a standard-aisle location with 60 served meals at $12 produces $720 revenue. If consumed ingredients average $4 per meal, wages for actual coverage total $200, prorated rent/holding fees are $92.50 (`$100 × 22/24 + $10 × 2/24`), and other operating costs are $30, operating profit is $157.50. At those assumptions, break-even is 41 meals after rounding up: `$322.50 / ($12 - $4)`. These are illustrative totals, not a fixed starter roster's wage schedule. Other locations and shorter opening windows use their quoted prorated costs and therefore have different break-even requirements.

This example assumes no waste or drink/dessert sales/costs and does not deduct equipment purchases from operating profit. A closed day in the example standard location incurs a $10 holding fee per retained stall, no unworked shift wages, and whatever spoilage actually occurs. Other tiers use their published holding fees. Reduced holding charges are a proposed safeguard against rapid default-closure losses at 24 game days per real day, while retaining a location-dependent cost for reserving scarce space.

### Cash protection and debt

The first release offers no loans, gifts, or player-directed wallet transfers. Validated helper wages are an explicit payroll payment into dining credit, with the corresponding restaurant expense and funded commitment. Buying stock, upgrading, hiring with an upfront fee, and acquiring a lease cannot spend cash already committed to obligations, including helper payroll. Available cash subtracts each commitment once; an expired or canceled commitment releases only its unused part. Operating liabilities are accrued explicitly; zero cash alone is not bankruptcy.

The overview displays forecast runway in real time, the next bill, and the effect of closure. A safety reserve can stop purchases and new orders before funds become critically low. Forecasts are estimates, with recent variation visible rather than implied guarantees.

If an obligation becomes due and cannot be paid, the restaurant enters distress and stops new trading and discretionary spending. Settle completed sales and funded earned helper wages, cancel unfinished orders using the normal reservation/waste rules, and cancel all purchase requests/offers/shifts. Record other wages and costs accrued through this transition, then stop work. A statement identifies the unpaid amount. The proposed recovery window is 24 available-service hours. During distress no new wages, rent, or holding fees accrue; remaining stock can still spoil. This prevents distress itself from creating an uncontrollable debt spiral. Pending manual requests cannot bypass distress even if they were authorized for an ordinary closed stall.

During recovery the owner may sell equipment or usable stock back to the system at a disclosed discounted salvage value and surrender leases. Salvage cannot exceed acquisition cost or the current replacement purchase value, and cannot transfer assets to another account. The same commit removes the surrendered items and records their cost-basis/proceeds effects; liquidated ingredients do not also remain in the warehouse or silently replenish wholesale stock. Paying all arrears restores a closed business, or a dormant one if no leases remain, for deliberate reopening. It does not renew the grace window on a query or failed payment. Otherwise the business becomes bankrupt at the fixed recovery deadline; the owner may accept bankruptcy immediately.

## 12. Reputation, awards, and optional milestones

### Reputation

Reputation reflects recent eligible completed and failed service. Use a bounded window of finalized visit outcomes, rather than aging away the score merely because a stall is closed, with an initial neutral value and sufficient history to avoid one order determining its identity. Window size, neutral-prior weight, and score weights are versioned content. Display quality, wait, value, and failures after accepting orders as the factors behind changes.

A temporarily closed stall does not lose reputation simply because it is closed. It forfeits current sales and may lose time-limited award recognition on schedule. Reputation uses simulated-service outcomes as specified in the visitor rules; guest outcomes remain separately visible. Long-lived businesses should remain open to challenge by new entrants.

### Awards that influence demand

Awards are periodic, visible recognitions for actual service, such as Service Excellence, Outstanding Value, or Cuisine Distinction. Use fictional Feud Hall awards rather than relying on real-world award brands.

Proposed first-release cadence is one review every seven elapsed game days, or seven available real hours, independently of the owner's cumulative invitation-earning clock. Publish the review deadline and scoring criteria. A restaurant needs a minimum of 50 finalized simulated-customer visits with a served main in the review window to qualify; optional desserts do not count as additional qualifying meals. A handful of perfect or guest-funded visits cannot dominate.

Use absolute qualification thresholds for core distinctions so that excellent solo play is rewarding. A separate best-in-hall or cuisine distinction may compare eligible rivals. Evaluate normalized quality, satisfaction, promised-wait delivery, and cleanliness; never compare raw speed across recipes with different intended durations.

Business-wide service/value judging aggregates eligible outcomes across all owned stalls rather than cherry-picking the best branch. Cuisine distinctions judge that cuisine's eligible finalized visits and apply only to matching stalls. The active demand benefit at any stall is bounded, initially at most 15% added attractiveness, for one review period. Multiple applicable awards do not stack beyond that cap. Renewing refreshes duration rather than multiplying the bonus. Award history and plaques remain after expiry.

Awards improve the chance of attracting suitable diners; they do not create guaranteed purchases, bypass budgets, or eliminate queue penalties. This makes an award useful without building a permanent compounding monopoly.

### Nonlinear milestones

Milestones are optional goals available in parallel. They are separate from award judging and do not form a mandatory quest chain.

| Example milestone | Achievement | Reward direction |
| --- | --- | --- |
| First profitable day | Complete an operating game day with positive operating profit. | Profile badge and sign customization. |
| A reliable kitchen | Serve 100 meals with a defined on-time rate. | Cosmetic counter detail. |
| Waste conscious | Finish a qualifying trading day below a published waste threshold. | Decorative plant or poster. |
| Cuisine specialist | Serve a substantial number of meals from one cuisine at sustained quality. | Cuisine-specific visual decoration. |
| A second counter | Open a second location and serve from it. | Expansion badge. |
| Adapt and thrive | Return to profit after a documented supply-price shock. | Business-history distinction. |
| Across the menu | Successfully operate several cuisines over a business's life. | Profile title. |

Exact thresholds are content data. Rewards are cosmetic or informational rather than permanent cash multipliers. Business milestones are tied to that venture; an owner's lifetime profile may remember them without transferring economic unlocks into a fresh restaurant.

## 13. Expansion, closure, and bankruptcy history

### Expansion

A restaurant can lease a second and then a third available stall within the same hall. Each requires sufficient uncommitted capital, setup time, equipment, and staff coverage. The owner chooses its location using the same visible exposure/rent comparison as a first lease. The UI previews the cost, break-even requirement, and expected additional overhead before purchase.

An expansion can target another cuisine, a different price/quality position, greater location exposure, or extra capacity for a successful menu. Shared ingredients and staff can improve utilization, but each new stall also competes with the owner's existing stalls for some diners and resources. Its published location factor applies normally; expansion itself creates no extra hall arrivals or free starter grant.

The owner can close and surrender one location, liquidate its equipment, and reassign its workers. Accepted orders must settle before releasing the slot. Recipe knowledge and the surviving business's record remain.

### Bankruptcy and a fresh start

Bankruptcy terminates the whole shared business. It closes all stalls, resolves/cancels pending work, settles funded earned helper claims, clears requests/policies, releases leases, and freezes an immutable final record. Remaining estate assets are removed from active play with explicit accounting and any unpaid liabilities stay in the failed estate; neither assets nor debts attach to the next venture or a guest wallet. Early acceptance of bankruptcy is available in distress, not as a free grant-reset command on a solvent venture. A failed venture cannot later earn money through delayed timers or resurrected processes.

The same account can immediately create a new named restaurant, subject to available space, using the same standard starting package as a first-time owner. It does not inherit the failed venture's cash, inventory, equipment, staff, recipes, reputation, or active award benefits. No assets may be transferred between ventures. Account-level purchase/request limits and guest-payroll transfer allowances survive a restart, and each new venture receives its grant exactly once. A personal dining wallet already earned through a guest role remains separate from the business estate and cannot become new restaurant capital. These controls must not turn ordinary bankruptcy into a restart cooldown.

The public owner history shows restaurant name, cuisines, opening and failure dates, peak stall count, earned distinctions, and final status. Private final statements contain the detailed financial cause. A business cannot be removed from the failure record by renaming it or restarting. Dormancy and voluntary location closure are not mislabeled as bankruptcy; surrendering the last lease follows the dormant-venture rule rather than silently granting a new business.

## 14. NPC competition and population changes

### The early hall

Launch with three NPC restaurants occupying three of the 150 slots. A human joining the early hall therefore has several visible rivals. Keep these initial rivals as humans arrive, then retire them gradually after the simultaneous-human threshold is met. At least three operating restaurants outside cleaning is the sparse-population target, not a demand to evict human leases when a mature full hall is quiet. Zero operating restaurants during 03:00–05:00 is required.

NPC profiles initially represent budget volume, dependable mainstream service, and premium quality. A computer-run owner chooses only among vacant, unreserved spots in [open rooms](#rooms): the lowest spot ID of its profile's preferred class, otherwise the lowest vacant spot ID. Budget prefers quiet spots; premium prefers standard spots rather than prime (owner decision, 2026-11-13), so a new hall's three NPC restaurants stand on `s001`, `s041` and `s042` in room 1 and both of its prime spots stay free. Their starting cuisines are drawn from the same twenty-five-cuisine catalog. They buy ingredients, pay costs, employ staff, wait for stations, and earn or lose money under the same rules. Decisions use public market information and their own private state; NPCs cannot read a rival's hidden inventory or future random outcomes.

They do not receive free recurring stock, infinite cash, privileged market allocation, or impossible throughput. Difficulty comes from strategy parameters and planning consistency. Each NPC venture begins with the same standard startup capital and pays its actual kit, lease, stock, and staff costs. Replacement after insolvency is a separately recorded venture under a stable NPC operator identity, so purchase/visitor-payroll limits do not reset. NPCs can choose recovery liquidation or accept bankruptcy rather than receive a hidden rescue top-up. Low-population operating schedules and rosters should provide overlapping coverage, including quiet hours outside cleaning, when economically feasible.

NPCs make bounded management decisions at meaningful event boundaries and a regular cadence, initially about once per game hour, or 2.5 real minutes. Each profile changes menus, price bounds, staffing, or purchasing for understandable reasons. Cosmetic activity alone is insufficient: an NPC purchase must actually compete for stock, and its menu/service decisions must affect the diner market. Faster reaction than a human can reasonably perceive is not the intended difficulty lever.

**Planning values (proposed tuning).** Two computer-run values are data and move with the customer tuning: the number of trays a computer-run owner stocks for before it has a previous day to go on, and the hours of each profile's starter shift. The expected-use method is unchanged. A hall runs on the first column until the [recorded rule change](ARCHITECTURE.md#the-recorded-rule-change) is applied; a new hall also starts on it, and the planner reads the new values at its next plan.

| Value | Current | Chosen (proposed, not applied) |
| --- | --- | --- |
| Fallback trays per day | 10 | 50 |
| Starter shift, budget | 05:00-17:00 | 05:00-17:00 |
| Starter shift, mainstream | 12:00-00:00 | 11:00-23:00 |
| Starter shift, premium | 19:00-07:00 | 17:00-03:00 |

The chosen shifts keep an open computer-run stall in every open hour and put a second one into the hours leading into each rush.

### Retirement policy

Proposed timing implements the confirmed threshold without reacting to every connection flicker. The minimum target concerns three distinct operating businesses, not three branches of one owner, so a solo owner with expansions still has competitors:

1. Count connected owners as defined above, deduplicated across windows and devices. NPCs, licensed owners without a current lease, guest profiles without an owner account, and owners operating only through unattended automation do not count as humans playing simultaneously for this threshold. Accepting a helper shift adds no extra owner to this count.
2. When at least 13 human owners remain present for five service minutes, latch retirement eligibility. Clear that latch only after presence is below eight for ten service minutes; intermediate counts retain its current state.
3. When eligible, at most one NPC per game day enters closing, and only if the remaining operating businesses would still number at least three. Settle its meals, helper wages, offers, and lease before releasing the slot. Store a solvent retired NPC as dormant for potential later reactivation, not as a fake bankruptcy.
4. If fewer than three distinct businesses operate for ten service minutes, prioritize restoring the floor using a dormant NPC or a new replacement, at most one per game hour, subject to vacancies and ordinary funds/coverage. Reactivating a solvent dormant NPC uses retained assets and a new lease, not another grant. Initial hall bootstrap still creates its three starting NPC ventures together.
5. A population evaluation takes one direction: restoration first if below the floor, otherwise retirement if eligible and the post-retirement floor holds. Do not retire and replace/reopen the same competitor in one evaluation. Announce transitions and preserve their deadlines across retries.
6. During cleaning, suspend NPC entry/retirement evaluations and pause their presence-stability/operating-shortage observation windows, retaining prior eligible progress. Reevaluate after scheduled reopening at 05:00; the mandatory zero-service interval never triggers replacement or grants competitors extra stock/capital. NPC business management may continue for planning.

NPCs never exceed the 150-slot limit and never displace a human lease. The floor is a target subject to available slots and viable staffed businesses, not permission to mint resources. If a mature hall is fully leased to closed human ventures, service and helper offers may be temporarily unavailable; show truthful availability rather than promise a definite reopening. Ordinary vacancies and dormancy provide the return path. A pending first-location applicant may trigger early NPC retirement before the population threshold, but only through the same settlement/capacity rules and with the projected operating floor preserved by the incoming/remaining businesses.

After platform recovery, clear incomplete human-presence observation windows
and retirement eligibility, then require a fresh five-service-minute observation
of at least 13 connected owners before any new population-driven retirement.
This explicit exception to ordinary hysteresis prevents old socket presence
from authorizing retirements. Already committed NPC closing work still settles;
recovery does not resurrect it or grant replacement capital. Cleaning alone
pauses observation progress and does not invoke this recovery reset.

NPC retirement and replacement should not cause abrupt supply or demand jumps. Use the next-day forecast and the same published scale rules. The feed identifies NPC ownership clearly, including when one is retiring.

## 15. Interface, 3D presentation, and audio

### Main views

| View | Decisions and information |
| --- | --- |
| Hall overview | Occupied stalls and available leases, ownership, exposure/rent comparisons, operating state, queues, awards, public menus, and navigation. Show hall access state and time until 03:00 closure or 05:00 reopening. The lease list includes vacancies outside the current camera view. |
| Business overview | Cash, operating profit, runway, urgent issues, staff coverage, stock risk, and all owned stalls. |
| Stall management | Menu, prices, ingredient-substitution policies and cost/quality previews, dietary compatibility/reach, capacity, equipment, queue, staff assignments, and current service results. |
| Wholesale market | Primary/substitute products with price, supply, yield and storage comparisons, next replenishment, purchase requests, fills, and explicit restock policies. |
| Staff | Hiring, skills, wages, fatigue, shifts, breaks, and reassignment. |
| Visitor work | Available helper offers, own shift/task status, posted wages, work history, earned dining credit, and visible license-qualification progress. Owners enable and end shifts through their staff view. |
| Restaurant licensing | Guests see eligibility, Apply, and their application/status/history. Authorized seed/admin reviewers see a pending queue with evidence, approve/reject actions, and decision history. No private reviewer queue is exposed to ordinary visitors or owners. |
| Development | Recipes, equipment, storage, training, expansion, and costs/prerequisites. |
| Cuisine selection | Equal-area world map highlighting available cuisine regions, synchronized with a searchable cuisine list and recipe/equipment/cost preview. Used for starter choice, expansion, and cuisine refits. |
| Performance and history | Profit and cash-flow reports, waste, customer feedback, awards, milestones, and prior ventures. |

The business overview is the default management home. The player can inspect a competitor's public menu and visible queue without seeing its private finances, inventory, wage contracts, or policy thresholds. Public comparison uses awards, service indicators, and visible business behavior; a mandatory public cash-balance leaderboard is not required.

### Gameplay interaction model

The owner-confirmed landing view is **Business overview with live hall context**.
Players manage by selecting a business/stall, inspecting an issue or opportunity,
previewing a change, and explicitly applying it. Staff continue ordinary work
without repeated player clicks. There is no required avatar travel, camera
precision, drag gesture, or reflex interaction to manage a restaurant. The full
hall is one primary navigation action away; its scene and equivalent stall list
select the same entities as business controls.

Proposed owner navigation is **Business, Hall, Market, Inbox**, with account,
language, and accessibility controls in the shared header. Business contains
Overview, Menu, Stock, Staff, Development, and Reports, plus an explicit
all-stalls/selected-stall scope. Show that scope beside edits so changing a
branch menu cannot look like a business-wide policy change. Visitors instead
get visiting/dining, available work, their receipts/inbox, and account access;
licensed owners without a lease see setup/waiting-list options. Reviewer actions
appear only under current explicit capability. Role changes preserve the same
principal and never imply permission merely because a navigation item is shown.

The owner-approved visitor UX is **hall-first**, with **Hall, My visit, Work,
Profile** navigation. Hall opens the shared live 3D scene with an equivalent
stall list; selecting a stall exposes its public menu, prices, availability,
waits, and dietary compatibility. Desktop can place the selected menu beside
the scene; a phone opens it as a detail screen with Back, rather than keeping
the scene behind the form. Browsing requires no owner invitation or avatar
travel, and never exposes private business controls.

My visit contains main/optional-drink checkout, accepted-order tracking,
dining receipts, and the later same-stall dessert offer. Where space allows,
show the selected stall's cuisine artwork alongside checkout; during a visit,
keep it tied to the stall fulfilling that order. Hide the illustration on narrow
layouts so it does not crowd the controls. The
[diner interactions](#milestone-5-diner-interactions) link browsing and tray
tracking across Hall and My visit. Work contains available offers, disclosed
pay/duration and success criteria, and a focused
[counter view](#milestone-5-counter-helper-interactions) for prioritizing ready
trays and staging pickup supplies. Profile
contains dining credit with available/reserved amounts, receipts/notices, work
history, account access, and license eligibility/application status. A successful
shift offers an explicit application; the pending view explains manual review
without promising approval, review timing, or a vacant stall. These screens
teach through ordinary play and use the existing dining, workforce, identity,
and cleaning rules. Mockup prices, balances, and frozen progress snapshots are
illustrative, not approved tuning or client authority over game outcomes.

The overview answers **Are we trading? What needs attention? Are we making money?
What can I change?** Show current operating state, available cash versus committed
cash, clearly labeled period profit, stock/coverage risks, and the next relevant
clock boundary. Keep a compact live hall/selected-stall view alongside those
decisions on larger screens. Exploring the hall replaces that compact preview
with the full hall workspace; returning to Business restores the preview. Show
only one hall view at a time. The hall clock, connection status, critical stop,
and cleaning countdown remain easy to find without crowding every metric into
a persistent phone header.

Selecting a recipe, product, worker, lease, or notice opens its context and next
valid actions. Quick reversible edits use a labeled draft and Apply/Cancel;
economic purchases show the bound quote, affected scope, total, recurring cost
where relevant, and pending/settled distinction. Only consequential actions such
as accepting bankruptcy need a separate consequence confirmation; do not put an
extra modal after every price edit or helper selection. Pending requests cannot
be submitted twice by repeat taps, and stale quotes show what changed. Use the
same offers, rejection reasons, and command receipts at every screen size.

### Learning through ordinary play

There is no separate mandatory tutorial, scripted practice economy, or sequence
of screens that must be visited to unlock normal management. The ordinary entry
view offers **Visit the hall**, **Work a shift** for unlicensed visitors, and
**Run a restaurant**, with accurate admission requirements. A guest may explore cuisines and startup costs
without an owner license, but draft previews grant no lease, money, or owner
capability. License approval remains manual with no promised wait; full halls,
missing shift offers, exhausted dining allowance, and cleaning show truthful next
options rather than invented work/customers or a tutorial bypass.

Use progressive disclosure within actual tasks:

- **Service readiness** remains useful throughout a venture: show the actual
  feasible main, stock, scheduled coverage, opening/attendance policy, and each
  blocking state with a direct action. Warn about a weak margin without making
  profit a new hard opening requirement. Starter defaults are prefilled and
  disclosed through normal setup confirmation; they never secretly enable
  unattended trading, purchasing, hiring, or optional recipe unlocks.
- **Explain at the decision:** menu prices show contribution and dietary reach;
  stock shows servings/reservations and expiry; staffing shows game hours and
  their real duration; leases show exposure and open/closed rates. Short inline
  definitions and expandable details replace a glossary that must be read first.
- **Explain the result:** real sale/fill/wage receipts and reports show what
  happened and why. Suggestions point to current opportunities, such as missing
  stock or an upcoming coverage gap, without guaranteeing profit or spending
  automatically. Keep noncritical hints dismissible and available again in
  context; essential costs, failures, and authorization reasons stay visible.
- **Teach visitor work at the counter:** show the ready tray, selection deadline,
  ordinary handover time, actual pay/standby, and license-success criteria beside
  the controls. One clear tap/keyboard action selects a tray; no tutorial overlay
  or decorative movement can obscure the short actionable window.

Guidance reacts to committed state and is not a quest system. Opening an
explanation performs no domain action, resets no deadline, and produces no
reward. During 03:00–05:00, readiness explains the real reopening conditions and
offers planning/manual management; it cannot promise immediate service or clear
absence/safety holds. Measure uncoached first-time play by time to a useful
action and understanding of costs/absence, rather than promising instant owner
admission. Validate English/Japanese context and input without introducing a
fluent-speaker review gate.

### Responsive layout and input

Support browser-style whole-page zoom in the desktop client: Cmd on macOS or
Ctrl on Linux with `+`/`=` to enlarge, `-` to shrink, and `0` to reset to 100%.
These shortcuts scale the complete interface and trigger responsive reflow;
they preserve drafts and focus and are separate from the 3D hall camera zoom.
Remember the native UI zoom level across restarts, including a saved reset to
100%. This is a local presentation preference shared by this installation,
independent of accounts and the 3D camera. Web browsers retain their standard
page-zoom shortcuts and preference handling.

Smartphone browser support is part of the core web game, not a reduced companion
dashboard. Ownership/setup, map/list cuisine choice, menus, stock/market,
staffing, dining with drink/dessert, helper tasks, licensing/review, recovery,
history, and settings must remain usable. Native phone apps remain later scope.

Proposed layout ranges use **available CSS width**, not physical screen pixels
or a device-name test; tune the exact breakpoints with content and text zoom:

| Available space | Proposed arrangement |
| --- | --- |
| Compact, strictly below 400 CSS px (confirmed) | Compact header with time/status and language selection; labeled bottom navigation with safe-area spacing. Hall selection opens a separate stall-detail screen with Back. Owners choose a business section and location, with one section visible at a time. Preserve drafts, selected IDs, camera and focus through sections, Back/Forward and resize. |
| Small, 400–719 CSS px | Existing reflow remains available; further navigation refinements at this size are proposed. Keep core actions readable and reachable. |
| Intermediate, about 720–1199 CSS px | Workspace with collapsible navigation and an optional detail drawer where it fits; preserve comfortable field/row widths. |
| Wide, about 1200 CSS px and above | Navigation rail, business workspace, and selected-item inspector/live hall context. Extra-wide screens can expose more stall comparisons, market rows, and report detail alongside the active task. |

More space provides useful simultaneous context rather than oversized text or
the same narrow phone column surrounded by empty margins. Keep prose/controls
readable; do not require panels to be permanently visible when unused. The same
editor becomes an inspector on desktop and a full detail route on phone,
preserving drafts, selected IDs, scroll/focus, and IME composition through resize,
orientation, language changes, and browser Back. Price/cost confirmation cannot
disappear behind the virtual keyboard or device safe areas.

Reflow essential management content at 320 CSS px and test larger widths and
zoom; maps and genuinely wide ledgers may have their own labeled pan/scroll
surface with equivalent usable summaries/actions. Product/staff rows become
readable stacked rows/cards rather than shrinking a desktop spreadsheet. Do not
hide critical costs, deadlines, warnings, or Apply/Cancel actions to make them
fit. Use approximately 44×44 CSS px or larger primary touch targets, readable
editable text, no hover-only information, and menu alternatives to drag/pinch.
See W3C guidance on [reflow](https://www.w3.org/WAI/WCAG22/Understanding/reflow.html)
and [touch targets](https://www.w3.org/WAI/WCAG22/Understanding/target-size-enhanced.html).

Bound scene detail/resolution on high-DPI phones and large displays. Reduce or
pause cosmetic rendering when appropriate, while keeping the HTML management
game available. Layout changes do not pause the economy or change attendance;
phone suspension/disconnection follows the existing server liveness/grace rules.
On return, preserve drafts, mark stale state, resynchronize, and resolve uncertain
commands by their original IDs. Never silently enable unattended trading or
replay a stale purchase because a phone resumed.

### Cuisine selection map

The cuisine picker uses an **equal-area world map**, with all available cuisine
regions highlighted against the dark background. Proposed projection:
[Equal Earth](https://proj.org/en/stable/operations/projections/eqearth.html),
which preserves relative area in a whole-world view. Keep its aspect ratio when
resizing; zoom and pan may improve legibility without enlarging selected regions
independently. Small regions receive labels and generous interaction targets,
not geographically inflated shapes. The map is part of the first playable UI,
including starter setup, expansion cuisine choice, and refitting.

The picker previews all recipes for the selected cuisine, using the hall's
active catalog. It identifies the starter recipe and the recipes that can be
unlocked later, with labels for mains, drinks, and desserts.

Author a geographic footprint for every cuisine's stable content ID. Footprints
represent the menu's regional inspirations and may be subnational, cross-border,
multipart, or overlapping; do not force one cuisine into one modern country.
Mughlai/Punjabi remains one choice and European remains one broad choice.
Levantine uses a broader Levant regional footprint rather than only Lebanon's
outline; author its exact extent with the other cuisine-map presentation data.
Javanese uses an authored Javanese regional footprint on Java rather than
highlighting all Indonesia or automatically treating all Java as one tradition.
Berber/Amazigh, Yoruba, and Tamil use appropriate cultural-region footprints
rather than inheriting the countries of the categories they replaced. These are
approximate culinary regions, not exclusive claims about where food belongs.
Exact footprints and labels are presentation-content work to complete before
the picker ships; every one of the twenty-five choices must have visible coverage.

The Indigenous cuisine footprints use approximate homeland reference areas for
orientation. Use community-sourced geography and support multipart and
overlapping geometry. Keep territorial and jurisdictional boundaries out of
the cuisine legend. The Haudenosaunee footprint draws on the eastern Great
Lakes, Finger Lakes, and St. Lawrence region. The Diné (Navajo) footprint draws
on the Colorado Plateau. The Lakota footprint draws on the northern Great
Plains and Black Hills. The Coast Salish footprint draws on the Salish Sea
and lower Fraser. The Māori locator covers the two main islands of
Aotearoa/New Zealand for orientation, without representing iwi boundaries. Use the same stable IDs in map, list, and
English/Japanese previews. [Haudenosaunee Confederacy](https://www.haudenosauneeconfederacy.com/who-we-are/) · [Mohawk Council of Akwesasne](https://www.akwesasne.ca/about-us/our-community/) · [Diné Nihi Kéyah land history](https://dinelanduse.org/history/) · [Oglala Sioux Tribe](https://www.oglala.gov/) · [Coast Salish Gathering](https://www.coastsalishgathering.com/about-gathering) · [Burke Museum Coast Salish geography](https://www.burkemuseum.org/collections-and-research/heritage/artscultures/coast-salish-art/coast-salish-people).

For cuisine selection, **Eastern Thrace is exclusively Turkish**. Include it in
the Turkish footprint and exclude it from the European footprint, including
highlighting, labels, hit testing, and overlap candidates. This is an
owner-confirmed assignment for the game's cuisine regions.

Hover or keyboard focus highlights a region and its cuisine name; click/tap
selects it for the normal menu, starter-kit, equipment, and cost preview.
Overlapping regions expose all matching cuisine choices in a labeled chooser
rather than silently selecting the topmost polygon. Use outlines, labels, and
selection states alongside color so neighboring or overlapping regions remain
distinguishable. Selecting a cuisine in the list highlights the same footprint;
map selection selects the same list item. Previewing or moving around the map
does not purchase a kit, refit a stall, reserve a lease, or change the cuisine.
The ordinary explicit confirmation and server validation still apply.

Keep an equivalent searchable HTML list available alongside the map, with all
choices reachable by keyboard and screen reader, including small or overlapping
regions. Localize cuisine names, region labels, legend, instructions, and
previews in English/Japanese. Preserve selection and map position through live
updates and language changes. Use a 2D vector map independent of the hall's
WebGL scene; if it fails to load, the list still completes the same flow.
Highlighting means available cuisine content, not guaranteed affordability or
recipe unlocks: show those conditions in the preview. Geography and polygon size
grant no demand, price, skill, or progression advantage.

### Continuity, action offers, and notices

Live updates preserve selected stalls, camera position, expanded panels, filters, sort order, keyboard focus, and unfinished edits. A new tick does not reset a form, move its confirmation button, or overwrite a draft price. Show the latest committed value and the local pending draft separately when they differ.

Useful action offers include an affordable purchase quantity, expected dish margin, valid shift assignments, expansion eligibility, and a lease/setup quote. Prepare them through application queries using the same pure domain calculations that commands enforce. Label the revision, assumptions, price limit, and pending-settlement status. The command revalidates current facts; a quote is not permission to spend after conditions change.

Show essential consequences before commitment: all setup and recurring costs, partial-fill behavior, expiry and spoilage exposure, unattended-operation spending authority, closure policy, and bankruptcy scope. Use progressive disclosure for optional detailed policies so a new player can complete the entire starter loop using safe preselected defaults.

Separate short action feedback from durable notices. Persist stockout/safety-stop summaries, distress and lease warnings, important award results, invitation acceptance/earning, license eligibility, and application decisions with the transition that caused them. Replays do not duplicate notices. Consolidate recurring symptoms rather than emitting a warning per tick. Dismissing a toast does not delete business history; invitation and application status must agree with current terminal outcomes.

Provide owners with a business inbox and guest principals with their dining/work receipts and notices. Optional out-of-app delivery requires a verified destination and explicit notification preferences; it is not a prerequisite for play. Linked/unlinked contact status and delivery failures are visible. Financial reports default to game-day and recent-session periods, with short real-time summaries suitable for one-hour game days. Load older history on demand with bounded pagination; normal ticks do not reload the entire ledger.

### UI languages and localization

English (`en`) and Japanese (`ja`) are required in the first playable release, across web, Linux, and macOS. Japanese is an acceptance language for the complete product flow, including public visiting, owner setup/management, all twenty-five cuisines and 125 recipes, dining/desserts, helper work, licensing/review, reports, notices, validation, connection failures, and recovery. A localized shell around English-only gameplay text is insufficient.

Expose an **English / 日本語** language selector before sign-in and in settings. Initially follow a supported browser/OS language, with English as fallback; retain an explicit choice per browser/installation. Switching language preserves the principal/session, hall/stall selection, in-progress orders/shifts, drafts, focus, and economic state. Player-entered restaurant/account names, application reasons, and other user text remain as entered. The Feud Hall brand may remain unchanged; provide localized descriptions and labels, with original dish names available where useful.

Translate complete messages with parameters and contextual terminology for game time versus available-service/real time, costs, substitution penalties, and confirmation actions. Format numbers, dates, and durations for the selected locale while preserving exact values. The currency remains virtual dollars, with its symbol/meaning clearly labeled in Japanese; switching language never converts money to yen, rounds away cents, changes units, or shifts the shared hall clock into Japan's timezone. The cleaning window remains 03:00–05:00 game time in either language.

Use readable Japanese glyphs, appropriate line breaking/punctuation, and layouts that accommodate both translations at supported widths and text zoom. Verify buttons, dialogs, tables, tooltips, accessibility labels, and 3D signs/list alternatives without clipped critical text or missing glyphs. Japanese input methods must work for names and forms: composing/converting text must not trigger Enter-to-submit or gameplay shortcuts, and live ticks must preserve the unfinished composition. Published text limits must accommodate ordinary Japanese names and agree with authoritative validation.

Implement new screens and notices in both locales as they are introduced. Hosted CI checks catalog/placeholder completeness, rendering and workflows in both languages, exact numeric round trips, Japanese input, and packaged-client font availability. Pseudo-localization helps expose layout assumptions; it does not replace actual Japanese. Maintain a shared English/Japanese terminology glossary and check consistent terminology, parameters, and units in critical confirmations. Detailed implementation boundaries are in [the architecture's localization contract](ARCHITECTURE.md#localization-and-presentation-boundaries).

### Visual language

Use charcoal or deep navy backgrounds, bright cuisine accents, clear white or pale text, and restrained luminous highlights. Cuisine accents should aid identification while signage, names, icons, and models remain sufficient without color. Critical warnings should be distinct from decorative neon.

The hall is a stylized, readable 3D diorama, with cuisine-specific counters, staff activity, visible queues, signage, and award plaques. Clicking a stall or selecting it from a list focuses the camera. Orbit, pan, zoom, hover feedback, and a reset-view control support navigation. Camera movement can be reduced or disabled.

The selected stall exposes **Menu**, **Counter**, and **Staff** controls in a toolbar below the 3D scene, with **Stock** available at owned locations. Do not float action buttons over the rendered stalls. **Focus on the hall** expands the scene and places its action panel alongside it; clicking a stall in this mode selects and focuses it without opening its tablet or workbench. Pointer clicks open the in-world tablet only when they hit its screen; clicking the counter, signage or another diner’s tray must not open it. Your own served tray remains clickable for collection. E opens the selected counter while the scene has keyboard focus. The same actions have ordinary labelled button/list equivalents, and closing the panel restores focus without moving the camera.

Each stall has a physical digital tablet mounted on its counter. Diners tap the tablet, or choose Menu/Counter, to bring its screen into readable view. Dish labels wrap at word boundaries (with Japanese-aware breaks), and each price stays intact; fit the complete label and price within the row without clipping. Error messages use word-aware wrapping across rows and red text, with an explicit attention message so color is not the only signal. While the in-world tablet is visible, display refusals, connection problems and uncertain-outcome retry controls there without duplicating a page-top banner that moves the scene. Keep screen-reader announcements and ordinary notifications available outside that tablet flow. A new error automatically opens the page containing its explanation, including after a later-page confirmation; routine live updates do not repeatedly pull the diner back to that page. The screen offers dietary filters, available mains and optional drinks, and a compact server-quoted review with the ordered items and their prices, total, estimated wait and explicit confirmation. Do not list individual ingredients on the tablet review; retain the complete bound ingredient/substitution terms in the confirmation payload. It then displays committed service and any eligible dessert offer. As soon as the server completes the visit, reset the tablet to its initial menu with an empty order selection; do not linger on a served status, recent receipt, expired estimate or old review/loading state. Keep receipts in My visit, and preserve an active dessert choice until it is accepted, declined or expires. Do not insert an order-status section above the Hall scene when an order is accepted or served: keep its position stable, with immersive status on the tablet and conventional progress/history on My visit. Page controls, keyboard navigation, English/Japanese text, and an optional accessible text equivalent support the same actions. Stepping back restores the previous hall camera; do not open a conventional checkout panel for this immersive dining flow. Helpers can inspect a funded offer, accept/leave a shift, stage supplies, yield, and select ready trays at their assigned counter. Owners use the same menu, purchasing, opening/closing, scheduling and staff controls as Business at the selected owned location, including from behind the counter. Owner self-purchase and helper-work restrictions still apply. Tablet and workbench actions use the same authorized use cases as the regular UI; tapping an item alone never purchases it. One shared draft, quote and pending-command state serves every surface, including retrying the same uncertain command on the tablet. Keep the workbench mounted when switching scene size or losing WebGL so inputs, focus and composition survive; narrow screens can place it below the scene.

The hall is drawn as the [row of rooms](#rooms) in section 6. Each stall stands at its spot's fixed position in its room and never moves when other stalls arrive or leave. Corner stalls face the room's centre diagonally; wall stalls face into the room, away from their wall. The centre of each room holds tables and seats as scenery, clear of the queues and of the paths between the doorways and the entrance. The entrance in the middle of each room's south wall is an open doorway onto the street. Doorways to open neighbouring rooms are open; a doorway toward a closed room holds a shut door, and the end rooms have a blank wall instead. A vacant spot in an open room is an open bay with a "to let" sign.

The scene has a current room. It draws that room in full, open rooms directly next door at reduced detail, and nothing beyond them; a room two doorways away is not drawn. The viewer moves between rooms by walking through an open doorway, with the **Halls** control below the scene (one button per room, closed rooms disabled with the reason), or with `[` and `]` while the scene has focus. Selecting a stall anywhere moves the camera to its room. An owner's first view frames the room of their first stall; a visitor's frames room 1. If the current room closes, the camera moves to the highest open room at or below it. Selecting a "to let" bay with the pointer, or **View spot** in the list, opens a spot panel with its class, exposure, rent, holding and set-up fees, the rent line from [scarcity rent](#scarcity-rent), and the existing reserve or lease action when the viewer may take it. The bays are selectable by pointer only inside the 3D view; the list's **View spot** buttons are the keyboard and no-WebGL route. The list view groups stalls and vacant spots under a heading per open room, and the location pickers group their options by room.

Each room has walls with street-facing windows and a ceiling. When the camera is outside, the nearby walls and ceiling cut away to keep the stalls visible. From inside, the windows look onto a tree-lined street with hills beyond.

Stall fronts and side walls show an illustration of a dish from the stall's cuisine. The stripe below the counter carries the localized cuisine name. The artwork and label represent the cuisine across menu changes and trading hours.

The first arrow key from an overview/orbit view enters walking at eye level in a clear aisle facing an open stall, preferring the selected stall when it is open. Start with a level viewing angle rather than inheriting the overview’s downward pitch or clamping its distant position onto the floor. If no stall is open, face a closed counter; an empty hall uses a level central view. Subsequent movement and returning to a saved walking view preserve the player’s position.

With the 3D view focused, Up and Down walk forward and backward at aisle height. Left and Right turn in place. Holding Shift with Up or Down tilts the view, and holding Shift with Left or Right steps sideways. Walking stays on the floor of open rooms and around stalls; it passes through doorways between open rooms but not through a shut door or out of the entrance.

Owners can choose **Inside my stall** in Hall to look outward from behind their
own counter, selecting a location when their restaurant has expanded. Drag or
use the look controls to turn; keyboard movement stays within the booth. Hide
the proprietor figure at that viewpoint, while staff and customers remain
visible. Closed shutters stay closed. **Return to hall** restores the previous
hall camera, and Reset camera returns to the overview. Preserve the viewpoint
across page changes; losing the location or owner access returns to the hall.
This is a presentation option and performs no gameplay command or attendance
change. Visitors retain the public hall and stall-list views.

Cooking emits heat and steam, an unstaffed station looks inactive, a sold-out item is marked, and a safety stop has an inspectable indicator. Closed stalls show a corrugated metal shutter with a spray-painted closure label in the selected language; the shutter rolls down when a stall closes and up when it opens, and snaps to its new position under reduced motion. Open stalls show a proprietor figure and, in the detailed view, one figure per on-duty staff position. A visitor helper represents their assigned counter position. The proprietor figure represents the business even during unattended service. Smoke and steam are feedback, not an independent physics simulation.

People are proportioned figures built in code, with arms and legs, several hair styles, and varied clothing and build. Owners wear an apron so they can be told from diners and kitchen staff. Distant and reduced-detail people are drawn more simply but keep their silhouette. A person's look stays the same for as long as they are in the hall, and walking people fade in and out smoothly.

Closed stalls display a counter placard with the next expected reopening in hall time when an opening is queued and current conditions support a forecast. A stall with an unset reopening time displays that status. The stall inspector and list show the same information.

### Performance and truthful animation

Use instancing and level of detail for crowds and repeated objects. Render the current room in detail, open neighbouring rooms more simply, and other rooms not at all. A full hall must not require every client to animate every diner or receive every restaurant's private state.

Server events describe order and station state, work remaining, effective speed, and hall time. Clients animate between updates. A completed visual progress bar does not award money before the server confirms service. On reconnection, animation rebuilds from current authoritative state rather than replaying hours of effects.

The first release may render representative crowd density at overview distances. Counts and detailed inspection must remain accurate; representative figures must not masquerade as extra paying customers. Physical customer pathfinding and collisions are cosmetic. A walking animation finishing never authorizes an economic transition.

Waiting diner figures vary in clothing color, skin tone, and height. Diners enter and leave through the room's entrance and fade in or out at the street end of it, as described in [Diners on the floor](#diners-on-the-floor). Reduced motion skips walking.

A diner can click their own served tray on the counter to see two arms reach out from the camera, take the tray, and lower it out of view. F while the scene is focused and a labelled Take tray control offer equivalent access. Only private committed service facts create these personal trays; main/drink share a tray and a served dessert has its own. Collection is cosmetic: service, payment and dessert eligibility never wait for the animation or require another economic command. Reduced motion removes the tray immediately. Keep collected trays gone across live updates and scene remounts for the current client session; recent uncollected completed courses remain visible for 30 real seconds of available hall time.

After a committed handover, the served customer steps out of the queue, walks along their own row to the counter beside the queue, takes the tray there, and leaves away from the queue carrying it. Neither the customer nor the tray passes through anyone still waiting. The counter tray represents current handover work, and a customer's tray fades with that customer. A cancellation produces no food-carrying departure.

### Diners on the floor

**Owner decision (2026-11-13):** at a busy stall the owner sees a queue, a few people wandering between stalls, and people eating at tables nearby. The rest of this section is the designer's call. Spec: [Project 3](superpowers/specs/2026-11-13-livelier-hall-design.md#project-3-visible-diners).

What the floor shows:

- **Queues.** Each stall's queue is drawn to the smaller of the server's queue limit (sent in the hall view as `queue_limit`) and a drawing cap of eight. In the room the viewer is in, every stall's whole queue is drawn, simplified for stalls not drawn in detail; neighbouring rooms show only the first diner of each queue and the diners eating. The stall's "orders waiting" number is the server's count and stays exact; it never waits for a figure to arrive.
- **Arrivals.** A diner who joins a queue walks in through the room's entrance, passes one or two other stalls, and ends at the back of the queue. A diner who leaves without buying walks in the same way and walks out again through an entrance of an open room, chosen deterministically.
- **Serving.** When a diner is served, the diner at the last occupied queue spot takes the tray at the counter and carries it to a free seat in the room. It eats for about a minute of real time, then leaves through the entrance. If no seat is free it leaves carrying the tray, as diners did before. A table never blocks or delays a sale.
- **Desserts.** A dessert order is staged from a diner who is already seated in the room, who returns to the queue, where one exists.
- **Closed hall.** From 03:00 to 05:00 the floor is empty. Figures on the floor when cleaning begins walk out and are gone within a few seconds.
- **Loading and reconnecting.** The floor starts from the current counts. Nothing replays and no crowd rushes in. A diner served before their figure reaches the queue turns to the counter from where they stand. A first load that stays slow past about a second and a half plays a short, purely decorative film-framed intro of the hall opening (never under reduced motion or without WebGL); see the [hall opening intro design](superpowers/specs/2026-11-15-hall-opening-intro-design.md).

Truthfulness. Every figure is staged from a diner the server committed, and the client never adds one. Each figure is staged from a change in the server's counts: a rise in a stall's waiting count, a rise in arrivals not matched by admissions, or a dessert offer. The client may delay a figure, route it, and simplify it; once a room holds its drawing budget of walking or seated figures, further walk-outs are not drawn and further joiners appear at their queue spot without walking in. This is the representative-crowd allowance above, used in one direction only: figures may be omitted, never invented. Walk-outs are staged from arrivals minus admitted, not from the "left" total, because "left" also counts admitted diners whose order later failed. Individual diners are not identified, so the staging is count-true, not identity-true. Reasons for leaving, and any per-stall count of lost diners, stay out of the public view.

Reduced detail skips browsing walks: diners appear at their queue spot and eaters are static. Reduced motion shows nothing walking, and eaters are static. Neither changes any count.

Proposed defaults (tuning values, not validated): eating time 60 s of real time; a drawing budget of 96 walking or seated figures per room; a queue drawing cap of eight; walking speed 1.6 m/s; cleaning clears the floor within 8 s; a gap of more than 10 s between server snapshots is treated as a reconnect and starts from the current counts; the client re-applying a view it has already seen (on a selection or label change) is not a new snapshot and does not shorten the gap. Technical contract: [hall presentation](ARCHITECTURE.md#diners-on-the-floor).

### The supply market

**Owner decisions (2026-11-13):** buying supplies is a 3D market where the owner clicks things to buy them: baskets of produce, a butcher's stall for raw meat, bins of grains and nuts. It is a row of vendor stalls, with a close-up of one vendor that puts a price tag on each container, and a cart; nothing is bought until the owner sends the order. The first time an owner opens the market a short note explains what the stars mean, then fades. Other owners are seen shopping, and a rival's cart shows its goods as 3D objects without labels. The market is on the Business page and is not part of the hall's 3D world. **Designer's calls, seen by the owner:** one click adds one crate to a draft cart; the order fills at the next clearing; supplies the owner's menu uses are starred; the text purchase form stays, for phones, no-WebGL and exact quantities; seven vendors cover the catalog. Everything else below is the designer's call. Spec: [Project 5](superpowers/specs/2026-11-13-livelier-hall-design.md#project-5-supply-market).

What the market shows, in the Supply section of the Business page:

- **Seven vendors**: Greengrocer; Butcher; Fishmonger; Dairy and eggs; Grains and nuts; Spices and tea; Bakery and pantry (bread, flatbreads, batters, noodles, sauces, broths, syrups, pastes). Which vendor sells a product, and what it looks like (a shape and a colour), is presentation data keyed by stable product ID, not game data. Every catalog product has an entry; one with none is drawn as a plain crate at the pantry and can still be bought.
- **Containers that show real stock and price.** A fuller container means more stock left; its tag shows the published price and the crate size. A tag turns red when stock runs low and grey only when the market has none at all; a small stock is shown low, with a little in the container, never as empty. A substitute sits beside its primary with a visible difference: frozen, plain sack (value), or box (preserved: canned, dried or chilled).
- **Stars.** A supply the owner's menu uses (including the substitutes of its recipe lines) is starred. The first-visit note about stars is announced politely to assistive technology, never takes focus, and fades; it is remembered per device and is not a gameplay fact. The meaning stays findable: pointing at or focusing a star shows the same one-line explanation, and a legend under the shelves explains the star and the markers above.
- **The draft cart.** A click adds one crate, but only from the vendor in focus: in the whole-row view a click focuses a stall, because containers there are too small to pick by accident. Each line shows crates, an estimated cost and a price limit that defaults to the published price plus 10%, rounded up to a whole minor unit, and can be edited. It is a willingness-to-pay limit, as ever. A limit typed in a form that cannot be a limit (such as "2.50") stays in the field, marked with a short message, and "Send order" waits until it is fixed, so nothing goes out at a limit the owner did not see accepted. A line whose product stops being offered stays in the cart, marked unavailable, and is skipped when sending; only the owner removes it. The cart says so before sending when a line would replace a request already waiting for that product, when the published price has risen above the line's limit, and when the line asks for more than the market holds.
- **Send order and "On its way".** "Send order" submits one purchase request per line through the same path as the text form; nothing is requested before it. "On its way" lists every request the server reports as waiting for the owner's restaurant and the outcome of each recent one, wherever it was sent from: the market, the text form, another device, before a reload, or restock automation (marked "automatic"). A line shows waiting, then filled, short (with how much arrived and why) or rejected (with the reason), and leaves 60 seconds after its outcome was first shown, or when dismissed; a dismissed line stays hidden. A line this page just sent says "sent" until the server's next report includes it; one that report never lists, with nothing replacing it, says "settled" with a pointer to the stock. Sending a product again replaces its waiting request, and the list shows one line for it. While a filled or short line is listed, the crates that arrived (what filled, divided by the crate size, rounded up) stand on the owner's cart in the picture, closed with a green lid, in their own group beside the draft crates so neither hides the other; in a stall's close-up the cart stands in the foreground at a size where both groups can be counted roughly. They leave with the line. An uncertain send is resolved by its own command ID, never sent again.
- **Rivals.** A rival who had a purchase fill is seen pushing an unlabelled cart past the stalls, loaded with the goods bought, sized to one of the three cart sizes. Pointing at a rival shows the restaurant's name and nothing else. A rival never blocks a click on a container. Reduced motion shows rivals standing in the aisle instead of walking, for 20 seconds. On load and on reconnect the market does not replay old clearings as a burst of shoppers. The owner's own trip is not staged for the owner, who is already watching their own cart.
- **The list is the market wherever the picture cannot be.** The scene needs a panel at least 720 px wide and WebGL. Without either, or if the picture fails, a list of vendors and goods with the same cart, limits, stars, low and out-of-stock markers and "Add a crate" buttons is the market, and it says so. Every action in the picture exists in the list and by keyboard. The picture is created the first time it comes on screen and draws only while it is on screen.
- **The hall's Stock panel** keeps its text controls and gains an "Open the market" link. Starter stock, restock automation and pricing policy remain text controls. No delivery animation is added to the hall scene.

Truthfulness. A container's fill and tag, a line's outcome and a rival's trip all come from what the server committed. The owner's cart in the picture holds the draft, which is plainly not yet an order, and, marked as arrived, the crates of fills the server has committed; a rejected, pending, unconfirmed or settled line puts nothing on the cart. What happened to each line is told in words in "On its way", including how much did not arrive. A rival's trip is drawn after the fact, from a committed fill.

Proposed defaults (tuning values, not validated): the crate size, cart-size boundaries and number of clearings kept described under [What is public about purchases](#what-is-public-about-purchases); a container is "low" below 300 of 1,000 of its target stock; the price limit defaults to 10% above the published price; a line leaves "On its way" 60 seconds after its outcome (or "settled") was first shown; at most eight rivals are drawn at once; the picture needs 720 px; the owner's cart in a close-up spans about 13% of the picture's width, and each group on it shows at most 36 crates.

### Audio and accessibility

Provide ambient chatter and spatial station sounds such as sizzling, chopping, and counter activity. Active cooking drives station loops; closure stops them. Resume audio after the browser permits it through user interaction, and provide separate ambience, effects, and master volume controls.

Management, visitor dining, and helper tasks must work through accessible HTML controls as well as 3D selection. Include keyboard navigation, clear focus, text labels, readable contrast, scalable text, reduced motion, and non-color status cues. Drag-and-drop staff management needs an equivalent assignment menu. Essential warnings and outcomes do not depend on audio.

If WebGL is unavailable or its context is lost, retain a functional management/list view with a clear rendering-status message. The economic game remains usable while 3D recovers.

## 16. Authoritative simulation and domain boundaries

Use one simulation ruleset behind two execution adapters: a local authority with durable saves for single-player, and an authoritative Elixir/Phoenix service on Render with PostgreSQL for multiplayer. Svelte/TypeScript management UI uses Bun and Oxlint, Three.js supplies presentation, and Tauri packages Linux/macOS clients. Multiplayer web/native clients share the public economy; local saves are separate economies. Rendering and UI clocks never determine economic outcomes in either mode.

The [architecture document](ARCHITECTURE.md) owns implementation contracts for
[DDD and aggregate ownership](ARCHITECTURE.md#domain-driven-design),
[Clean Architecture](ARCHITECTURE.md#clean-architecture-and-aggregate-ownership),
[CQRS](ARCHITECTURE.md#cqrs), [AOP techniques](ARCHITECTURE.md#aop-techniques-and-cross-cutting-wrappers),
and the [pure core and imperative shell](ARCHITECTURE.md#functional-core-and-imperative-shell).
Start with a modular monolith, explicit domain ownership, and one simulation
authority per hall. These boundaries preserve the gameplay invariants rather than
requiring separate services or a process for every diner or worker.

The [clock and cleaning rules](#5-time-opening-hours-and-owner-absence) define the
player-visible behavior. [Simulation scheduling](ARCHITECTURE.md#simulation-scheduling)
specifies exact due-event ordering, the hard 03:00 cutoff, authoritative command
timestamps, and recovery from unobserved gaps. Domain decisions remain pure and
only recorded events evolve authoritative state.

## 17. Commands, state synchronization, and authorization

Owners manage only their own ventures; visitors control only their own orders,
wallets, and assigned helper tasks; licensing reviewers need explicit current
permission. NPCs and unattended policies obey the same economic rules. Every
private query and live payload respects current authority, including after
helper handover, role changes, and credential revocation.

The [command inventory](ARCHITECTURE.md#core-command-families),
[receipt contracts](ARCHITECTURE.md#commands-state-synchronization-and-authorization),
[authorized projections](ARCHITECTURE.md#public-and-private-projections), and
[reconnect protocol](ARCHITECTURE.md#reconnection-and-optimistic-ui) live in the
architecture document. Clients show committed outcomes and preserve drafts;
disconnected views are marked stale, and uncertain submissions resolve the
original command ID rather than creating another purchase or payment.

## 18. Persistence, recovery, and deployment

[Deployment](DEPLOYMENT.md) owns the release procedure and package checklist;
the architecture defines its persistence, authority, and compatibility contracts.

Full gameplay event sourcing is the adopted persistence direction. Committed
business actions survive restarts; downtime cannot accrue economic costs or
expire player-rights deadlines, and recovery cannot duplicate wages, grants,
licenses, or notifications. Pure replay restores facts; a separate idempotent
live reconciliation restores safe control before the simulation resumes.

The [event-sourcing ADR](decisions/0001-event-sourcing.md) records the decision,
alternatives, and tradeoffs. Detailed [persistence and replay contracts](ARCHITECTURE.md#event-persistence),
[authority and deployment](ARCHITECTURE.md#deployment-and-clients),
[content/client compatibility](ARCHITECTURE.md#content-and-client-versions), and
[early qualification](ARCHITECTURE.md#early-qualification-and-ongoing-tests) are
maintained in the architecture document. Its capacity and recovery targets
require implementation measurements. Desktop distribution and updates must
respect the [native platform constraints](ARCHITECTURE.md#native-distribution).
The Linux release pipeline must generate both Flatpak and `.deb` packages and
verify installation, launch, and connection to the authoritative server for each
format on its supported target environments.

## 19. Observability, balance, and acceptance

### Measures that explain the game

Collect enough information to answer why businesses succeed or fail: served and lost demand, reasons for rejection/cancellation, queue distributions, customer preferences, price and margin changes, stockouts, waste, staff coverage/fatigue, operating profit, safety stops, distress, and failure causes. Separate human/NPC ownership, simulated/visitor demand, allowance/payroll funding, and automatic/helper control; these are independent dimensions.

Operational monitoring covers scheduling delay, command/commit latency, database failures, projection lag, reconnect/resync rate, mailbox growth, authority changes, and recovery errors. Diagnostics should link related orders, fills, and commands without exposing private credentials.

Design success is more than technical uptime. Playtesting should show that each cuisine can support a viable strategy, several price/quality positions are competitive, a first-time owner understands a loss, NPCs challenge a solo player, and a leading restaurant can be contested without restarting the hall.

### Technical target workload

Validate at 150 occupied stalls, including an expansion-heavy distribution and an all-human one-stall distribution. Proposed peak qualification includes 150 owner sessions, 150 visitor customer sessions, and 150 helper sessions, with distinct guest profiles where possible: up to 450 concurrent connections, rather than treating the stall cap as a user cap. Helpers still require real funded support positions, so low-population tests show limited offers rather than inventing positions. Include opted-in automation, NPC transitions, meal peaks, and market contention. Public browsing load and admission limits are recorded separately.

Proposed initial targets are sub-500 ms server-side acknowledgement for ordinary management commands under the target workload, public/private state freshness within two real seconds, and a usable 30 fps low-detail hall view on an agreed integrated-GPU reference machine. Purchase fills follow the published clearing interval. These are acceptance targets to measure, not current performance claims. Hardware and offered server capacity must be recorded with results.

### Required correctness scenarios

1. Two businesses compete for the last ingredient units without negative stock or duplicated fills.
2. Several simultaneous purchases across a restaurant's stalls cannot overspend its wallet or storage capacity.
3. A diner visit finalizes at most once; each accepted course, reserved ingredient batch, production stage, sale, wage payment, award, and lease settles at most once.
4. Duplicate commands, lost replies, process crashes, and deploy reconnects preserve committed outcomes.
5. An unauthorized owner cannot inspect private rival projections, assign rival staff, or spend rival funds.
6. Closing after absence respects the grace period, stops new orders, settles accepted work, and stops unworked wages and routine restocking.
7. Opted-in unattended operation respects budgets, price ceilings, shifts, cash reserves, and stop conditions over many game days.
8. Server downtime creates no catch-up bankruptcy or disproportionate benefit for the first owner to reconnect.
9. Expansion and NPCs respect the same 150-slot cap, including simultaneous acquisition attempts.
10. Population-driven NPC retirement obeys the deduplicated connected-owner condition, hysteresis, and post-retirement distinct-business floor. Licensed owners without a current lease do not count; present owners with a closed paid stall count once. Early first-location admission is a separately recorded exception. Restoration and retirement cannot cancel each other in one evaluation.
11. A failed restaurant remains archived, releases its leases, and cannot transfer assets or receive late revenue after a fresh venture starts.
12. Recipe access, inventory freshness, station capacity, staff fatigue, and queue abandonment produce the same results when replayed from committed state.
13. Customer choices preserve total arrivals and include no-purchase outcomes. Adding an expansion cannot directly multiply the arrival pool.
14. Award eligibility works with one human and with many rivals; repeated awards do not compound beyond the cap.
15. All twenty-five cuisines can complete the entire purchase-to-service loop for their savory, dessert, and drink recipes through both the management interface and authoritative simulation.
16. Concurrent invitation redemption, expiry, revocation, lost responses, session revocation, and account recovery preserve one account, one parent, and exact quota accounting. Restaurant restart never rewrites ancestry or repeats a seed grant.
17. Human-player counts and invite earning exclude NPCs, spectators, duplicate sessions, and extra stalls. A full hall can accept an account invitation without charging or promising an unavailable lease.
18. Every successful transition immediately releases invalidated reservations, jobs, workers, market requests, and leases. Event-derived state/projection changes match the declared change set; no durable gameplay mutation bypasses events.
19. Read-side offers and write-side rules agree at unchanged-state boundaries; suggested default restocking and staffing plans actually complete a controlled service cycle.
20. Live ticks preserve drafts, focus, selection, and camera position. Transaction failure produces neither success notices nor an externally deliverable invitation.
21. An uninvited visitor can complete a meal order at a human or NPC stall through the ordinary stock, queue, production, and revenue rules; another visitor cannot inspect or change that order.
22. Guest reconnects, duplicate submissions, concurrent spending, and new sessions cannot duplicate an order or exceed its funding/admission budgets. Earned money remains spendable independently of allowance issuance. Guest traffic cannot create owner privileges or eligible simulated recognition; an existing owner's presence is counted only once.
23. At the same committed batch position, genesis replay, snapshot-plus-tail replay, and live execution produce equivalent canonical state, balances, clocks, random continuation, and notices. The subsequent live recovery-reconciliation batch is a new transition, not a requirement that interrupted helper control remain byte-identical. Deleting derived tables does not lose authoritative history.
24. Historical event versions remain interpretable after content and code changes. An incompatible snapshot falls back safely; a missing or unsupported required event blocks recovery instead of being ignored.
25. Multi-stream event append, expected versions, request receipts, fencing, and required projections are atomic across crash and retry boundaries. Projection checkpoints cannot advance beyond their committed effects.
26. Historical replay cannot send mail, repeat invitations or grants, or generate new customer/NPC decisions. Duplicate event delivery cannot duplicate projection effects.
27. Location exposure influences simulated diner choice without increasing total arrivals. Higher exposure increases expected opportunity under otherwise identical conditions, while quoted rent and holding costs match actual prorated charges. Starting and expansion leases use the same rules, and replay preserves accepted location terms.
28. The hall closes at 03:00 and reopens customer access at 05:00 each game day: five available real minutes. All customers leave, dining/helper admission stops, unfinished orders settle/cancel once, and planning/reporting/manual purchases remain available. Only schedule-, attendance-, and safety-eligible stalls reopen; owners may choose additional closures.
29. An uninvited visitor can accept an opted-in human/NPC counter-helper offer, perform a real task, earn wages, and spend that credit on a meal. A successful shift unlocks applying for a license; work alone grants no owner permissions or invitation issuance.
30. Concurrent shift acceptance, multiple windows, duplicate task messages, reassignment, and late messages after handover cannot duplicate a worker, task completion, sale, or wage interval. The controller generation is enforced.
31. Payroll debit, visitor credit, and settlement receipts balance and commit once; funded wages survive failure, unused commitments release, and guest reconnect/profile recovery cannot duplicate or erase earned credit.
32. Disconnect, idle, shift expiry, backing-worker break/end, owner absence, closure, safety stop, NPC retirement, and bankruptcy release helper control correctly. Fallback preserves progress and normal service without reopening a stopped stall or counting a helper role as an additional owner.
33. An expired onboarding draft releases only its reservation, with no starter grant or failed-business record. Confirmation is atomic; reload/retry cannot duplicate assets or expire a paid lease. Dormancy/reopening cannot obtain another grant or a second solvent venture.
34. Device-bound guest bootstrap and lost-response retries create one principal per bound attempt. Guest-to-owner promotion preserves wallet, inviter uniqueness, and email collision rules without implicit profile merging. Ended/revoked capabilities stop private live payloads, not just new commands, and an old guest channel cannot become an owner channel by retaining a cached role.
35. Accepted prices, content versions, deadlines, and funding slices survive menu changes and reconnects. Raw expiry, ready-food expiry, cancellation, and handover use the specified tie ordering and waste/reservation treatment.
36. Invitation accrual counts qualified intervals once per owner across all stalls. Seven cumulative trading days, paused time, cap clearing, business replacement, guest exclusion, and calendar-based award reviews remain distinct.
37. Ready standby and task coverage accrue one position's wages once, including fractional carry. Shift acceptance funds both payroll and cross-window transfer authorizations; business replacement and new guest credentials cannot reset employer/hall limits or claw back earned credit.
38. A solo owner with three stalls is still one competing business; restoring NPC competition targets distinct ventures without exceeding capacity, resetting NPC operator budgets, or injecting free rescue stock/cash.
39. Clock partitioning within the same declared availability interval preserves outcomes. Long-gap recovery, cross-clock exact boundaries, immutable receipts, uncertain commits, and recovery reconciliation preserve head state without outage pay, stale helper control, or revived credentials.
40. Duplicate menu entries do not multiply stall demand weight. Location exposure applies once, arrival accounting preserves source totals, and guest sales are separately reported without inflating competitive reputation or award eligibility.
41. Refit, worker training, storage disposal, and surrender of the last lease preserve or explicitly release affected jobs/assets/claims. Discounted liquidation cannot leave both sale proceeds and the same active items, and only actual bankruptcy permits the fresh grant path.
42. Purchase, reservation, preparation, service, raw/ready-food spoilage, cancellation, and estate closure reconcile raw inventory and work-in-progress. Each ingredient cost is classified once as served cost or loss; accrual and payment cannot duplicate wage expense.
43. Command/projection serialization round trips preserve integer money and event positions, including values beyond JavaScript's exact numeric range but within the server's declared bounds. Domain calculations, displayed quotes, fingerprints, and receipts agree on the canonical representation.
44. Reaching the accepted shift end with a completed helper-selected handover grants eligibility exactly once, including service at the end-time boundary outside cleaning. Early, recovered, or standby-only shifts still settle earned wages but do not grant eligibility. Client/owner claims cannot forge completion proof; employer bankruptcy after successful completion cannot erase it.
45. An eligible guest explicitly submits an application and authorized seed/admin reviewers see it in their queue. Duplicate submission/review, rejection, withdrawal, reapplication, lost replies, and invitation-redemption races preserve one license, one immutable parent, and correct unused invitation quota. Approval never creates a second wallet, lease, business, or starter grant, even when the hall is full.
46. Ordinary owners, seed descendants, NPCs, and revoked reviewers cannot read the private queue or approve applications. No self-approval is possible. Offline approval survives restart without creating a session, inheriting admin powers, or replaying a notification. Applicant status and reviewer decisions remain consistent through recovery and projection rebuilds.
47. Primary and substitute products compete for finite market stock and shared warehouse space under the same budgets. Resolving several recipe lines against the same stock cannot over-reserve it; non-unit conversions reserve/consume the exact required quantities. An infeasible full bill is unavailable, with no partial reservation or hidden purchase.
48. Changing substitution policy, market prices, or content after acceptance cannot change an order's bill, quality penalty, or price. Stale visitor quotes requiring a different variant need reconfirmation. Expired reservations can use fresh batches of the same bound product only; otherwise cancellation releases claims and classifies costs once.
49. Each supported variant applies its bounded quality penalty exactly once, and its actual consumed cost flows through inventory, work-in-progress, served cost or waste. Human/NPC policies and simulated/visitor orders follow the same resolution rules; only eligible simulated outcomes affect competitive reputation/awards. Content validation rejects invalid conversions, unsupported alternatives, and insufficient coverage across the launch catalog.
50. Boundary traces immediately before/at/after 03:00 and 05:00 reject customer admission/service throughout cleaning, clear unfinished meals and funding once, and preserve already earned helper pay. A helper ending at its disclosed cleaning-truncated deadline can qualify from earlier completed work. No reopening catch-up diners or cleaning-driven NPC replacements appear.
51. Cleaning preserves clocks, spoilage, holding costs, and absence/security deadlines while stopping production wages and invitation accrual. Reports at 03:00 reconcile a labeled 24-hour period, or initialization's explicit partial period, including cutoff waste. Recovery midway through cleaning preserves its remaining duration and cannot duplicate reports, settlement, or reopen transitions. Maximum-service rent/traffic/earning calculations use 22 trading hours; 05:00 cannot clear a manual closure, absence hold, or safety/business stop.
52. Every cuisine has three savory recipes, one dessert, and one drink with validated ingredient/equipment requirements. A diner can accept dessert only after a served main at the same stall; forged parents, a canceled main, another principal, another stall, an expired choice, or a second accepted dessert are rejected without course effects. Concurrent sessions, cancellation, and retries preserve the consumed dessert slot.
53. Optional dessert does not duplicate arrivals, allowance grants, completed-main counts, invitation activity, or award eligibility. The initial main/drink tray and later dessert use separate funded settlements and actual inventory costs; a dessert failure cannot undo the main's successful payment. Finite cold/baking/assembly resources and the 03:00 cutoff apply normally.
54. Visits finalize once after dessert settlement, decline, unavailable offer, timeout, or closure, with the declared normalized course weights. A visit without an accepted dessert gives no dessert penalty; a failed accepted dessert affects its own component. Simulated/guest recognition separation and fixed award review cuts survive reconnect, replay, crashes, and projection rebuilds, including a main served before a review boundary and a visit finalized afterward.
55. Every first-playable flow has complete English and Japanese messages, content labels, accessibility labels, and notices. Both locales remain usable at supported widths and zoom, including long translations, Japanese punctuation, 3D/list views, empty/error states, and offline/recovery screens. A release cannot pass through silent English fallback for missing Japanese entries.
56. Switching language during an active main/drink/dessert order, helper shift, licensing action, or pending command preserves canonical IDs, request fingerprints, money, quantities, clocks, receipt outcomes, drafts, and selection. Localized formatting/input preserves exact amounts; Japanese does not select yen or reinterpret 03:00 cleaning as a timezone conversion.
57. Japanese names and application text survive IME composition/conversion, live ticks, language switches, reconnect, validation, and serialization without premature submission, lost text, broken character boundaries, or differing client/server limits. Verify real Japanese input on supported browser and native webviews.
58. English and Japanese core flows work in installed Flatpak, `.deb`, and macOS clients with the supported font/runtime strategy, including missing-font and offline startup checks. Catalog/placeholder and terminology-consistency checks complement visual/property tests.
59. Main/drink/dessert acceptance rejects stale confirmed prices, ingredient variants, recipe versions, or service deadlines without reservations or charges. A revised confirmation uses a new command ID and cannot extend the dessert offer window. Voluntary cancellation wins only before preparation; races, disconnects, and server-driven failure preserve exact funding/waste and the served main. One active visit per principal/hall and future-admission limits prevent concurrent duplicate visits without withholding an eligible cancellation.
60. First-location waiting-list offers follow compatible FIFO order, count toward capacity, expire once after ten service minutes, and cannot be bypassed by direct leasing, expansion, or NPC restoration. Rejoining/preferences, dormant reopening, insufficient funds, outage recovery, and confirmation races cannot create a grant or lease twice.
61. Midnight demand/budget and seven-day award boundaries remain distinct from 03:00 reporting and cumulative invitation earning. Invitation progress integrates only eligible intervals, including last-meal expiry and a first meal at an exact boundary, without retrospective credit. A newly initialized hall reports only its actual partial history.
62. Recovery requires fresh observed human presence before new NPC retirements, while preserving already committed closing work. Repeated recovery attempts at newer fencing epochs settle interrupted control once under one durable recovery identity; incompatible migrations cannot leave an old writer trading against a changing schema.
63. Cross-origin requests, stale/revoked sessions, and unauthorized native IPC cannot acquire gameplay capabilities. Queued private delivery rechecks current authority; logout/revocation clears cooperative client caches without promising to erase information previously received by a client.
64. Cuisine selection displays an equal-area world map with all twenty-five available cuisine footprints highlighted. Small, multipart, cross-border, and overlapping regions remain selectable; overlap disambiguation and the synchronized searchable list reach the same stable cuisine IDs. Eastern Thrace highlights and selects only Turkish, never European, in either locale. Equal-area projection fixtures, proportional resizing, keyboard/screen-reader access, English/Japanese labels, live-update continuity, and map/WebGL failure fallbacks are verified. Selecting or previewing a region cannot spend money, reserve a lease, or change economic rules before ordinary confirmation.
65. Dietary compatibility filters the actual offered bill before stall/dish scoring. Incompatible food has zero choice probability regardless of price, awards, location, or lack of alternatives; unrestricted diners may buy compatible restricted-diet food. Profile assignment partitions the same finite arrivals, and unmet dietary demand departs once without a service-failure penalty.
66. Vegetarian/vegan classification includes sides, sauces, pantry packs, animal stock/fat, gelatin, rennet, and substitutions. Missing metadata, misleading names, and forged badges cannot qualify a dish. Actual quantities/yields determine carbohydrate compatibility; supported combined requirements use intersection. Every enabled profile has a viable main in validated launch content.
67. Main, drink, and dessert share the visit's pinned dietary rules and carbohydrate ceiling. Exact acceptance/service/cancellation accounting cannot spend that allowance twice, reset it on reconnect, or reopen a canceled dessert slot. Incompatible dessert is omitted without penalty; later menu, policy, preference, or content changes cannot alter accepted composition or qualification. Human confirmation, NPC operation, projections, and replay agree in both locales.
68. Each cuisine has three savory recipes, one dessert, and one non-alcoholic drink: 125 recipes total. A drink is accepted only with its initial main at the same stall, at most once per visit; forged parents, later additions, replacements, refills, and standalone orders are rejected. Main-only checkout remains valid, and drinks cannot create arrivals, grants, invitation activity, or extra qualifying meals.
69. Main/drink checkout consolidates shared ingredients, capacity, exact funding slices, and dietary/carbohydrate commitments atomically. Any requested component becoming unavailable or changing confirmed terms rejects the whole guest checkout without partial acceptance. Simulated optional choice preserves one arrival and its original budget. One tray queue place and one counter handover cannot duplicate staff or bypass drink preparation.
70. Both tray components must be ready and fresh before joint service. Failure/expiry, cancellation, absence, distress, bankruptcy, and the exact cleaning cutoff settle or cancel the complete tray once, with actual consumed costs as waste, unconsumed commitments released, and no standalone drink payment. Voluntary cancellation ends when either preparation starts. Helper-selected tray completion counts as one task; replay/reconnect preserve tray membership and the consumed drink slot.
71. Main-only, main/drink, main/dessert, and main/drink/dessert visits finalize once with normalized main:drink:dessert weights 4:1:2 over accepted components. Optional items declined/unavailable add no penalty. Cleaning exemptions, independent later-dessert settlement, shared budget/carbohydrate limits, source eligibility, and fixed award review cuts remain intact. All drink names, quoted prices/ingredients, tray controls, reports, and failure states work in English/Japanese web/native flows.
72. A new guest can discover dining, real helper work, and license admission without a tutorial or economic bypass. An admitted owner can understand readiness, inspect real costs, open when eligible, explain a sale/loss, and choose an absence policy using ordinary screens. Full halls, manual-review waits, no work/allowance, cleaning, distress, and recovery remain truthful; hints never grant assets, change permissions, or reset deadlines.
73. All core role flows work at 320 CSS px and larger phone/tablet/desktop widths in English/Japanese, with touch, keyboard, zoom, and virtual keyboards. Responsive reflow/orientation, context-detail navigation and browser Back preserve scope, drafts, focus/IME, selected IDs, active work, and uncertain command identity. Essential prices, costs, clocks, and actions remain visible; no hover/drag/WebGL dependency blocks play.
74. Large displays provide useful simultaneous business/hall/detail context without another simulation subscription, duplicated editor, or extra economic action. Phone backgrounding, network change, and resumption obey ordinary absence/recovery rules, keep stale views explicit, and cannot enable automation, resume a safety-stopped stall, or repeat a purchase. Reference-device rendering and input performance are measured rather than inferred from a desktop screenshot.
75. A helper can prioritize a real ready tray with a visible wait and serve-by limit. Staging and service share one worker and counter. When readiness, staging, expiry, or closure coincide, at most one setup credit is earned and consumed, no service rule is bypassed, and wages and licensing proof follow the existing contracts.
76. Diners can compare viable orders, track a tray while browsing, and act on an eligible dessert from either view. Filtering, changing views, and looking at a receipt or tasting list create no visits or charges. An absent diner, failed renderer, or repeated pickup interaction leaves committed service, charges, and offer deadlines identical.
77. Room 1 is open in an empty hall. Leasing the last spot of a class in the open rooms opens the next room; a draft on that spot does not; a surrender that reopens the class closes an empty next room; a lease or draft keeps its room and every earlier room open; rooms open in a chain and never beyond ten. Open rooms are always a contiguous prefix that covers every lease and draft.
78. A reservation, lease, first-location offer or computer-run placement in a closed room is refused through the application boundary, and removing the room rule from the catalog makes the same reservation succeed. No draft or lease is ever produced in a room that was closed at that moment. A lease that opens a room offers it to the earliest compatible waiting-list entry in the same batch, and no offer is made for a closed room.
79. Scarcity quotes match the worked figures, including the cap, a class held below the next class up by the class gap, and a room opening lowering new quotes. Within fixed open rooms a class's quote never falls as it fills, and class order is preserved. A lease made from a draft records the draft's rent, not the higher current quote; an existing lease's rent and its later operating charges are unchanged by later quotes.
80. A managed hall that had leases in later rooms before the room rule arrived keeps every lease, spot and rent, and every room up to the highest lease is open. The upgrade records one catalog event, a repeat is refused, and a pinned spot missing from the launch layout stops the upgrade without an event. Events before the upgrade replay under the old rule, and live, genesis-replay and snapshot-tail state agree after it, including a snapshot at the head position and a PostgreSQL restart that does not record a second upgrade.

### Property-based testing

[Testing](TESTING.md) defines check selection, planned entry points, CI gates,
and execution/evidence policy, including Bun/Oxlint and Svelte coverage.

Property-based testing is required from the first economic-core milestone, using ExUnit/StreamData or an equivalent generator/shrinker with explicit budgets. Combine independently computed properties with fixed behavioral examples; do not make the oracle another call to the implementation being checked.

Generate boundary values and combinations for prices, cash/reserves, storage, batch sizes, both gameplay clocks, wall-time credentials, dietary profile/ingredient-composition rules and shared-course carbohydrate limits, main/drink tray states, expiry timestamps, queues, fatigue, 03:00/05:00 access and report boundaries, shift/control gaps, cuisine/recipe requirements, main/dessert visit states and deadlines, substitute mappings/conversions/policies and combined bills, slots/locations/leases, invitation quota, licensing completion proofs/application states/reviewer roles, wallet funding slices, cross-window payroll limits, principal roles, locale/message parameters, and Japanese/Unicode input boundaries. Include zero, below/equal/above limits and independent compound-condition outcomes. Rejected commands add no own effects relative to their post-advance baseline. Conservation checks account for declared sources/sinks such as wholesale replenishment, starter grants, simulated diner spending, allowance issuance, payroll transfers, spoilage, and salvage rather than assuming a closed system.

Use model-based command sequences that include creation, hiring, purchasing, substitution-policy changes and variant resolution, serving mains, offering/declining/ordering desserts, course cancellation and visit finalization, switching locale with pending actions and Japanese drafts, closing, cleaning cutoff/reopening/reporting, absence, automation, expansion, distress, bankruptcy/restart, invitations, guest shift acceptance/tasks/handover/wage settlement, dietary-profile selection and compatible main/drink/dessert acceptance, paired-tray preparation/service/cancellation, successful-shift eligibility, license application/review/withdrawal and reviewer revocation, and NPC entry/retirement. Race approval against invitation redemption and other terminal decisions. Check invariants after every command and clock event, not only at the end. Require nontrivial progress: accepted actions, completed sales, and targeted lifecycle states, so an all-rejected trace cannot pass vacuously.

Shrink with dependency-aware symbolic IDs and a small independent lifecycle model. Removing creation may remove its dependent actions, but assertions, unexpected errors, and unexpected service halts must propagate rather than being treated as harmless generator rejections. Record the original seed, content version, original/final trace, and violated invariant; promote reproducible minimized failures into a bounded checked-in regression corpus.

Run common traces through the pure model and, in a smaller sampled set, a disposable PostgreSQL adapter with restarts and injected commit failures. Check equivalent committed outcomes. Metamorphic checks include partitioning an already-declared available interval across the same events, splitting requests without gaining allocation priority, deduplicating sessions without changing owner counts, and replaying commands without changing balances or quota. A long unobserved outage is a different availability input, not a partition expected to accrue the same time. Use explicit clocks and seeds rather than timing-sensitive sleeps.

A test-only independent settled-state oracle checks for stranded claims and invalid lifecycle references, while a change-set auditor compares event-derived declared and actual state mutations. Prove the oracles are sensitive by introducing a known resource-release or accounting fault and observing the expected assertion fail. Architecture tests check dependency imports, event/aggregate and projector ownership, and the complete command/query inventory. Additional replay, schema-evolution, snapshot, and projection properties are required by [the architecture qualification plan](ARCHITECTURE.md#early-qualification-and-ongoing-tests).

### Mutation testing

Mutation testing is also required. Start with bounded, risk-focused cohorts on changes to money, reservations, lifecycle transitions, identity, scheduling, and commit/replay code. Use pinned tooling in an isolated disposable copy or hosted CI environment. Generated arithmetic/Boolean/comparison mutations are complemented by curated semantic faults; neither a high line-coverage percentage nor a small perfect mutation sample proves the game correct.

High-value faults include allowing a 151st stall; changing expiry equality; consuming ingredients twice; omitting a reservation release; ignoring a price ceiling or fatigue condition; turning a rejected commit into success; skipping authority fencing or request fingerprint checks; refunding invite quota twice; counting NPCs as human presence; and continuing absent-owner trading when automation was not enabled. Substitution cohorts bypass an approved mapping, ignore shared-stock requirements or yield conversion, drop or double a quality penalty, switch an accepted bill, or expense primary cost after substitute consumption. Cleaning cohorts admit a diner or complete handover at 03:00, retain a queue during cleaning, pay off-duty production wages, charge open rent, reopen a safety-stopped stall, or treat cleaning as NPC shortage/platform downtime. Dessert cohorts admit a dessert before main service, reset a used dessert slot on cancellation, issue another allowance, count a second meal/arrival, or finalize/score a visit twice. Localization cohorts drop a Japanese key/parameter, round a money value through floating point, treat locale as timezone/currency, or submit a form during IME composition. Helper cohorts skip a controller-generation check, retain control after closure, pay the same interval twice, or credit a wallet without its payroll debit. Licensing cohorts accept an unfinished task as successful work, skip current reviewer authorization, approve a nonpending application, reparent an existing owner, or attach a starter grant to approval. Event-sourcing cohorts also remove or reorder an event, alter its amount, omit an expected-version check, advance a projector checkpoint too soon, or execute side effects during replay.

Each cohort first passes its unmutated baseline in the same environment. Retain source/test hashes, exact mutation patches, selected tests, runtime, seeds, and the failing behavioral assertion. Use validated test selection including indirect use-case callers, property tests, and required SQL scopes. A survivor is replayed unchanged against the broader applicable tests; distinguish a test-selection miss from an actual missing assertion.

Report killed-by-assertion, survived, untested, invalid/compile failure, timeout, fixture/setup failure, and harness failure separately. Only a witnessed behavioral failure counts as detection. Do not classify an unproven survivor as equivalent or turn a timeout into a successful kill. Restore the original source and verify its passing baseline after each batch.

CI should gate critical changes on a bounded curated cohort and review of valid survivors, with broader generated/property exploration in bounded hosted runs. Record the tested scope and denominator rather than claiming a project-wide score. For each new critical guard or oracle, remove or invert the protected behavior once and demonstrate that the named test fails. Ensure branch outcomes, numeric boundaries, and independently evaluated condition outcomes are covered in addition to mutation checks.

Mutation and property workloads have explicit case/action/shrink/time limits and initially one mutation worker. Local full-suite runs require the owner's advance permission. Never run local `tsc`, directly or indirectly, because of its RAM usage; local `bun check` is allowed, including project-wide checking. Hosted CI supplies broad suites and the release type-check gate; local diagnostics still respect resource limits. These are implementation requirements; this design review runs only document validation.

## 20. First-release scope and implementation order

### Required first playable scope

The first playable target includes offline single-player with pause/resume and persistent online multiplayer, alongside the entire economic loop, all twenty-five cuisines with three savory recipes, one dessert, and one drink each, an equal-area world-map cuisine picker with highlighted regions and an accessible list, optional same-stall main/drink trays and later dessert ordering, hard dietary compatibility and profile-based demand, ingredient substitutes, automatic kitchen work, staff/shift management, shared supply and diner competition, default closure and optional unattended automation, mandatory daily hall cleaning/planning, NPC competitors, finite hall leases with visible location/traffic/rent tradeoffs, same-hall expansion, awards, optional nonlinear milestones, full gameplay event sourcing with saving/replay/recovery, bankruptcy with a persistent owner history, invitation-tree accounts with recovery, visitor customer play, optional counter-helper shifts with payroll-backed dining credit, successful-shift license applications with seed/admin review, and durable notices. English and Japanese UI, in-context onboarding, and responsive smartphone-to-desktop web layouts are required across the complete first-playable flow. Basic dark, brightly accented 3D presentation must reflect real state. Clean Architecture/DDD boundaries and property/mutation verification develop alongside these features.

Shipping just a 3D scene or just a collection of GenServers is not a playable version. A smaller initial internal slice is useful, but does not satisfy this scope.

### Implementation sequence

| Milestone | Deliverable | Exit condition |
| --- | --- | --- |
| 1. Economic core | Pure decision/evolution functions, initial versioned events, clocks, accounting, dietary compatibility/course limits, substitution resolution/quality, lifecycle, content, and architecture boundaries | Genesis replay equals live state; shrinking properties, a settled-state oracle, and a small mutation cohort exercise the first rules without UI/network. |
| 2. Durable shared simulation | PostgreSQL event store, atomic stream append, receipts/fencing, snapshots/projections, markets/diners/jobs, basic NPC adapter, and early capacity proof | Human/NPC rules agree; crash and snapshot/genesis recovery preserve committed facts; recorded 150-stall append/replay measurements qualify the storage approach. |
| 3. Management game | Invitation tree, owner/guest recovery, dining and helper shifts, payroll wallets, license applications/reviewer queue, starter setup using the three-cuisine backend catalog, menus/prices, market, staff, query offers, notices/reports, closure/cleaning/planning, automation, and English/Japanese text/layout | One human can manage against NPCs; a visitor can work, eat, and apply for a license; handover/payroll, admission/review/recovery races, and suggested-action outcomes are tested. |
| 4. Progression and population | Add the remaining twenty-two cuisines to complete the twenty-five-cuisine roster, qualify optional main/drink trays and later-dessert flow across it, add dining receipt history in **My visit**, unlocks, expansion, NPCs/retirement, milestones, awards, distress/history | The solo-to-populated loop and fresh-start lifecycle work end to end. Players can review their own completed visits, including earlier visits retained in the event log, and see what they ordered, what was served, and what they were charged. |
| 5. Hall presentation and visitor play | Stateful 3D stalls/crowds, camera navigation, accessible list alternative, audio, reduced detail, [counter-helper decisions](#milestone-5-counter-helper-interactions), and [diner interactions](#milestone-5-diner-interactions) | Visual state matches the economy. Diners can compare meals and follow pickup and dessert. Helpers can prioritize service and stage supplies with bounded effects. Management and both visitor flows work during rendering failure. |
| 6. Multiplayer release qualification | Full 150-stall workload, historical-event compatibility, archive/projection restore, security checks, property corpus, mutation evidence, Render operation, and Linux/macOS packaging, including CI-generated Flatpak and `.deb` artifacts | Recorded recovery/retention measurements, acceptance results, reviewed mutation survivors/selection, and verified English/Japanese web/native flows, font/input behavior, and installation for both Linux package formats and the macOS client. |
| 7. Offline single-player (planned) | Local authority using the shared rules, transactional local event storage, local-only onboarding, pause/resume, save compatibility/export/recovery, and server-free native/browser runtime delivery | The game starts and resumes with networking unavailable and no separately installed server/database. Closing/suspending advances no simulation time; crash/retry/replay preserves the committed local head; offline data cannot enter a multiplayer hall. |

The initial backend slice used Mexican. The follow-up after Milestone 2 replaces
that internal catalog with Mughlai/Punjabi, Sichuan, and Levantine and spreads
the three starter NPCs across them. Mexican remains part of the twenty-five-cuisine
launch roster. Build the common online web experience first, then package and
verify native multiplayer clients against the same server. This is the implemented path; the new offline slice extends delivery without retroactively claiming it already exists.

### Later scope

Private multiplayer halls; additional public halls; player-to-player trade or gifts; restaurant co-ownership/shared management; detailed cooking minigames and additional visitor staff specialties; tips; staff poaching; loans; standalone drinks, refills, and adding drinks after main acceptance; physical seating or crowd congestion as economic constraints; freeform kitchen construction; complex equipment failures; regional or offsite expansion; native iOS/Android and Windows clients; campaigns; monetization; and automatic desktop updates are outside the first release.

Private-hall compatibility requires service-level accounts plus hall-scoped memberships, leases, economy, configuration, and authorization now. Account invitations ship in the first release; separate private-hall invitations, access administration, and billing remain later work.

## 21. Tuning register and remaining production decisions

The owner has resolved the central concept, population, time, absence policy, failure model, cuisines, platforms, and delivery format. The following are concrete proposed defaults or production tasks rather than hidden requirements attributed to the owner.

| Item | Proposed baseline or required next decision |
| --- | --- |
| Maximum locations per restaurant | Three; validate expansion value and newcomer access at 150 total slots. |
| Newcomer vacancy reserve | Ten slots unavailable to expansion; adjust from admission and waiting-list results. Not implemented in the server yet. |
| Rooms | Ten rooms of 15 spots each (catalog `rules.rooms`: `count` 10, `per_room` 15), with the odd/even class mix in [Rooms](#rooms). The number of rooms and spots per room are proposed; the row of rooms and the opening rule are owner decisions (2026-11-13). |
| Scarcity rent | Cap 1.5× base rent (`scarcity_cap_permille` 1,500) with one spot of a class left in the open rooms, rising in a straight line from base; each class's quote at least $1.00 below the next class up (`class_gap` 100). Tune how strongly it spreads leases across classes. |
| Waiting-list allocation | Compatible FIFO for licensed first-location/reopening applicants; one entry per principal, ten-service-minute draft offer, no payment before confirmation, explicit rejoin at the tail after a missed/declined offer. |
| Presence grace period | Two available-service minutes before default closure; recovery does not charge outage time. |
| NPC retirement | At least 13 distinct present owners for five service minutes latches eligibility; at most one retirement per game day, preserving three distinct operating businesses when feasible. |
| NPC hysteresis/restoration | Normally clear eligibility below eight owners for ten service minutes; platform recovery clears it and requires fresh presence evidence. Below three operating businesses for ten service minutes, restore at most one NPC per game hour; never retire and restore in one evaluation. |
| Inactive leases | Dormancy after seven available-service days with neither trading nor owner management; reopening retains the venture and receives no new grant. |
| Market clearing | Ten real seconds; tune fairness, feedback, and stock volatility. |
| Supply market | Proposed: crate of about ten servings of the largest recipe line using the product, rounded up to 1, 2 or 5 times a power of ten; cart sizes small 1 to 3 crates, medium 4 to 9, large 10 or more; six clearings kept for the owner's outcomes and two for public trips; "low" below 300 of 1,000 of target stock; default price limit 10% above the published price; a line leaves "On its way" 60 seconds after its outcome is first shown; at most eight rivals drawn. Confirmed: the owner decisions in [the supply market](#the-supply-market) and [what is public about purchases](#what-is-public-about-purchases). Revisit after seeing real owners shop. |
| Arrival scale | Approximately 90 potential arrivals per business equivalent per day, floor three equivalents; calibrate adaptation and actual conversion. |
| Customer tuning | Chosen values are proposed and not applied to any hall: 248 potential arrivals per equivalent (current 90) with a one-hour peak of 30 at 12:00 and 28 at 19:00 (a sharper alternative, 252 with 34 and 33, is measured in the report), wholesale targets, per product in its own unit, of the larger of the current target and 100 times the largest quantity any recipe line uses (current: the larger of a base of 400 by default, more for named staples, and six times the starter mains' line quantity; no target falls), computer-run fallback 50 trays (current 10), and mainstream and premium starter shifts 11:00-23:00 and 17:00-03:00 (current 12:00-00:00 and 19:00-07:00). Details in [§7](#a-finite-pool-of-diners), [§8](#market-structure) and [§14](#the-early-hall). A hall stays on the current values until an operator applies the [recorded rule change](ARCHITECTURE.md#the-recorded-rule-change); the owner decides first whether rent, wages and prices should rise. Evidence and the choice of day shape: [report](superpowers/reports/2026-11-15-more-real-customers.md). |
| Economic scheduling | One-real-second wake-up, plus server-timestamped command advances; proposed unobserved gap over five real seconds enters recovery. Benchmark batching, readiness, and GC under the full owner/guest/helper workload. |
| Service windows | Confirmed hall cleaning closure 03:00–05:00 game time, five real minutes; owners choose service windows within the other 22 hours. No diner backlog accrues during cleaning. Tune overnight demand within the existing daily arrival budget. |
| Awards | Seven elapsed game days; 50 finalized simulated-visit minimum with a served main; guest outcomes separate; per-stall applicable benefit capped at 15% for one review period. |
| Distress | No new trading; 24 available-service-hour recovery; settle funded helper wages, cancel requests/shifts, and accrue no new wage/lease charges while distressed. |
| Fresh-start protection | Immediate restart after bankruptcy when space permits; one non-terminated venture, no estate asset/debt transfer, one grant per venture, persistent account purchase and guest-payroll transfer limits. Dormant reopening receives no grant. |
| Owner admission | Invitation redemption or successful-shift application approved by seed/admin players. Proposed success requires the agreed shift end and at least one completed helper-selected handover. Reviewer capability is explicit; approval sponsors the applicant in the tree without consuming invite quota. Admission is independent of stall availability. |
| License applications | One pending application per principal; manual review without game-time expiry. Set submission/reapplication service-time rate limits and optional motivation length. Show qualification before work and decision status afterward; fund wages independently of application outcomes. |
| Visitor dining | Set allowance issuance and admission limits. Preserve earned-credit spending independently of the grant budget. Only simulated meals affect competitive reputation/awards and invitation activity. |
| Visitor confirmation/cancellation | Pin confirmed price, variant, recipe and service deadline; reconfirm changed terms. Proposed free voluntary cancellation only before preparation; repeated cancellation bounds future admissions, not the right to cancel eligible existing work. Later server-driven failures release funding under ordinary waste rules. |
| Visitor shifts | One counter-helper role; five-service-minute default, up to ten; a proposed two-game-minute/five-service-second selection window followed by two-game-minute handover. Missing selection or the upper fifteen-service-second actionable-idle limit ends control. Pay attended coverage/standby once, backed by payroll and persistent employer/hall transfer limits. |
| Invitation quota and earning | Confirmed: one per 7 cumulative qualifying game days (7 real hours of qualifying time, with additional elapsed time for cleaning). Proposed: cap three available plus outstanding, seeds three; one simulated main served in the preceding game day plus staffed/solvent trading with a feasible main. Accrue once per owner and pause closed/ineligible time. |
| Invitation validity | 72 unaccelerated service hours, paused for platform outages; not three accelerated game days. |
| Location exposure and rent | Proposed tiers: quiet 0.8×/$80, standard 1.0×/$100, busy 1.25×/$150, prime 1.5×/$220 base rent per full open game day, before scarcity. Tune affordable and premium strategies against the same finite demand pool. |
| Closed holding cost | Proposed 10% of the slot's quoted full-day open rent (scaled with the scarcity quote); validate that normal absence does not rapidly destroy a new business. |
| Starter finances | Example $5,000 capital, $2,200 setup, $400 stock; balance all twenty-five cuisine kits. |
| Substitution balance | Most primary ingredients have a direct approved alternative; target cheaper typical cost or more dependable supply, never unlimited supply. Proposed quality loss: three points per substituted line, capped at nine on a normalized 100-point score. Tune with value/premium strategies and shortages; publish explicit signature-ingredient exceptions. |
| Dessert flow | Confirmed optional second course after a served main at the same stall. Proposed dessert cash unlock, 30-service-second human choice window, one accepted dessert per visit, normalized main:dessert scoring weight 2:1, and no added arrival or meal count. Tune seeded appetite, remaining budget, costs, and shared station contention. |
| Drinks and tray service | Confirmed one optional drink per cuisine alongside the main. Proposed non-alcoholic roster, independent cash unlock, same-checkout main/drink acceptance and joint handover, one drink slot, complete-tray cancellation, shared diet/funding limits, and normalized main:drink:dessert weights 4:1:2. Main:dessert remains 2:1 when no drink is accepted. Author work/holding times and equipment costs; tune attachment without changing the finite arrival pool. |
| Content data | Author the full 125 recipe bills (75 savory, 25 dessert, 25 drink), primary/substitute products with coverage and recipe-approved quantity conversions, ingredient shelf lives/prices, equipment stats, wages, shift templates, quality factors, and unlock costs before enabling them. |
| Demand model | Tune segment weights, budgets, patience, no-purchase share, and wait estimates through seeded simulations and human playtests. |
| Dietary demand | Hard compatibility before preference scoring. Proposed profile mix: 60% unrestricted, 20% vegetarian, 10% vegan, 7% carbohydrate-conscious, 3% keto-style. Author full-portion ingredient/derived-content facts and explicit per-visit carbohydrate ceilings; require a viable main for every enabled profile/combination within the existing catalog. All three items share the ceiling; report unmet demand without creating extra arrivals. |
| Automation defaults | Author conservative starting policies and explain their spending authority and residual liabilities. |
| Art and audio | Produce consistent dark/bright stall assets, readable cuisine signage, staff/crowd models, effects, and licensed sound assets. |
| Cuisine map | Confirmed equal-area world map with available regions highlighted. Proposed Equal Earth projection, authored footprints for all twenty-five cuisines, overlap chooser, synchronized accessible list, and English/Japanese labels. Select licensed geographic source data and record attribution, geometry simplification, and projection/export inputs. |
| Authentication and delivery | Implement device-bound durable sessions, verified-email recovery and collision handling, invitation hashing/replay, provider configuration, outbox delivery, and revocation; external OAuth is optional later work. |
| Verification budgets | Pin property/mutation tooling and CI budgets; begin with one mutation worker, explicit test scopes, independent oracles, and retained failure evidence. |
| Event-store implementation | PostgreSQL-backed application port with atomic cross-stream append, expected versions, ordered commit cursor, receipts, fencing, and outbox; qualify a library or the minimal adapter against these contracts. |
| Snapshot and recovery | Initially every 10,000 events or five service minutes; proposed snapshot-tail recovery/reconciliation within 30 seconds at target workload. Measure full replay of 30 real days of representative history and storage growth; protect credentials/receipts/delivery tracking in backups. |
| Mixed-session workload | Qualify 150 owner, 150 customer, and 150 helper sessions with real eligible positions; measure browsing/admission separately. |
| Deployment capacity | Choose an always-running Render configuration using measured simulation and database demand. |
| Localization | English and Japanese at launch; complete catalogs, contextual time/currency language, IME-safe forms, Japanese glyphs in packaged clients, and automated terminology/placeholder checks. Select a message-formatting library and font strategy against the architecture contracts. |
| Client support | Record minimum browser/webview/OS versions and a rendering benchmark machine. Verify macOS installation under the signing constraint. |
| Interaction/onboarding | Confirmed business overview with live hall context and learning through normal play. Proposed readiness explanations, contextual action/result guidance, Business/Hall/Market/Inbox owner navigation, and shared inspectors/details; validate uncoached first-time use and returning-player usefulness. |
| Responsive web | Confirmed smartphone usability with richer large-screen layouts. Proposed 320 CSS px core reflow, coarse-pointer targets around 44×44 CSS px, and content-driven single/two/three-region layouts. Qualify mobile Safari/Chrome and desktop targets, virtual keyboard/IME, suspension/resume, and reference hardware before publishing supported versions. |

An implementation plan should turn these defaults into explicit versioned data and acceptance checks. Unvalidated tuning should remain easy to change without rewriting domain logic.

Remaining content values, measured balance, and [architecture qualification](ARCHITECTURE.md#architecture-verification) are implementation work rather than permission to choose contradictory rules at runtime.

## 22. Source and decision trace

Primary design source: the 174-page PDF supplied as `feud-hall-design-discussion.pdf`. Its title is “Best Programming Languages for Tauri”; the game-design discussion develops later in the conversation. The source PDF remains an external reference and is not copied into this repository.

| Source location | Material retained |
| --- | --- |
| Pages 14–21 | Svelte, Linux/web/macOS, no paid Apple Developer account, functional core / imperative shell, domain-driven design. |
| Pages 32–40 | Solo viability, progression, and externally defined content; detailed progression rules here are proposed defaults. |
| Pages 42–55 | Render, persistence, live updates, and online presence as requirements to design correctly. |
| Pages 74–90 | Canonical Render server for web and desktop, authorization/reconnection concerns, and state-driven WebGL visuals. |
| Pages 93–114 and 139–163 | Crowd rendering, selection, camera navigation, labels, cooking animation, particles, and spatial audio. |
| Pages 115–126 | Competition for supplies and customers, multiple cuisines, staff management, demand-boosting awards, and expansion explicitly within the same food hall. |
| Pages 128–139 | Staff assignment, fatigue/shifts, recipe unlocks, cooking queues, and ingredient consumption. |
| Owner clarifications in this chat, November 7, 2026 | Persistent public hall, 150 physical stalls, NPC transition after more than twelve concurrent humans, automatic cooking, the initial cuisine roster (subsequently revised below), optional nonlinear milestones, bankruptcy history/fresh starts, one-hour game days, default closure with optional unattended automation, and repository Markdown delivery. |
| Owner account and architecture requirements, November 7, 2026 | Durable player-account invitation ancestry; pragmatic DDD/Clean Architecture, AOP/CQRS techniques, property-based testing, and mutation testing. Maintain frequent management decisions and automated NPC competitors. Contracts are defined in this document and [the architecture](ARCHITECTURE.md). |
| Owner visitor-play clarification, November 7, 2026 | Visitors may play as customers of stalls. Guest funding, admission limits, and recognition treatment above are proposed rules supporting that confirmed feature. |
| Owner event-sourcing preference, November 7, 2026 | Prefer full event sourcing while starting from scratch if viable. Adopted as the design direction with explicit early load/recovery/compatibility qualification in [the architecture decision](decisions/0001-event-sourcing.md). |
| Owner invitation-period clarification, November 7, 2026 | Earn one invitation per 7 cumulative game days of solvent trading, equivalent to 7 real hours of qualifying service; the subsequent cleaning window increases the minimum elapsed time. This supersedes the earlier invitation-period wording. |
| Owner location-tradeoff decision, November 7, 2026 | Better locations attract more foot traffic and cost more in rent, with the tradeoffs clearly visible. Replaces equivalent starting-location potential and deferral of location differentiation. Tier values and fixed-lease pricing are proposed implementation defaults. |
| Earlier owner opening-hours decision, November 7, 2026 | Originally allowed around-the-clock trading and optional breaks. Superseded by the mandatory cleaning decision below; additional owner-selected breaks and absence safeguards remain. |
| Owner visitor-staff decision, November 7, 2026 | Add optional short visitor helper shifts, owner opt-in and NPC offers, narrow task permissions, automatic handover, and virtual wages spendable on meals. Start with one helper role; detailed timing, controller, and payroll rules above are proposed defaults. |
| Owner architecture-document decision, November 8, 2026 | Maintain DDD, Clean Architecture, CQRS, AOP techniques, and detailed persistence/recovery contracts in a broader architecture document. Keep the event-sourcing ADR focused on the decision, alternatives, and tradeoffs. |
| Owner starter-cuisine revision | Replace the former Indian choice with Mughlai/Punjabi and South Indian, and Chinese with Sichuan and Cantonese. Retain Japanese, Mexican, Lebanese, and Thai. This established eight choices before the subsequent expansion below; specific dishes remain proposed. |
| Owner starter-cuisine expansion | Add Moroccan, Ethiopian, Peruvian, Turkish, Vietnamese, Indonesian, Korean, and European. This expands the earlier roster before the subsequent Persian addition below. European is one broad category; its dish mix and all other new dishes remain proposed. |
| Owner Persian addition | Add Persian alongside Lebanese and the other existing choices, before the further expansion below. Specific Persian dishes remain proposed. |
| Owner twenty-cuisine roster | Add Brazilian, Senegalese, and Colombian to reach twenty starter cuisines. This established the 60-savory-dish catalog, subsequently expanded by the dessert decision below; new dish selections and operational profiles remain proposed. |
| Owner dessert decision | Add one dessert to each of the twenty cuisines, retaining three savory recipes each (80 recipes total). Dessert is an optional course after a served main, bought from the same stall. Specific desserts, unlock costs, decision window, and scoring weights above remain proposed. |
| Owner cuisine-scope revision | Replace Moroccan with Berber (Amazigh), Senegalese with Yoruba, and South Indian with Tamil. Retain twenty cuisines and three savory recipes plus one dessert each (80 recipes). This supersedes the earlier category labels above; revised Berber/Yoruba dishes remain proposed and the Tamil menu is retained. |
| Owner Turkish dessert selection | Use halvah for the Turkish dessert. The proposed specific variant is sesame/tahini-based tahin helvası; quantities, preparation, and balance remain content proposals. |
| Owner Japanese-localization decision, November 8, 2026 | Include Japanese UI alongside English to verify localization is implemented well. Make full-flow coverage, layout/input, fonts, formatting, and automated checks part of first-playable acceptance. No fluent-speaker review is planned or required. |
| Owner cuisine-selection map decision, November 8, 2026 | Select cuisines through an equal-area world map with available regions highlighted. Equal Earth, footprint authoring, and interaction/fallback details above are proposed implementation defaults. |
| Owner Eastern Thrace assignment, November 8, 2026 | Eastern Thrace belongs exclusively to the Turkish cuisine region, excluded from the European cuisine region in the picker. |
| Owner Levantine revision, November 8, 2026 | Replace Lebanese with the broader Levantine cuisine category. Retain twenty cuisines and three savory recipes plus one dessert each; the existing proposed menu is retained and the map footprint broadens to the Levant. This supersedes earlier Lebanese category references in the decision history above. |
| Owner Levantine dessert selection, November 8, 2026 | Replace muhallabia with knafeh, retaining falafel wrap, chicken shawarma wrap, and mujaddara. Use an equipment-dependent dessert unlock with dairy costs and a short serving window; exact recipe, capability, prices, and timings remain content proposals. Supersedes the earlier dessert retained during the Levantine rename. |
| Owner Javanese revision, November 8, 2026 | Replace Indonesian with Javanese, retaining twenty cuisines and three savory recipes plus one dessert each. This supersedes the earlier Indonesian category in the decision history above. The narrower map footprint and revised pecel starter are proposed content details. |
| Owner frontend-tooling decision, November 8, 2026 | Use Bun and Oxlint in place of `tsc`/ESLint CLI workflows. Native `bun check` provides local and hosted TypeScript checking; preserve qualified Svelte coverage. The local prohibition applies specifically to `tsc` and its indirect invocation, not to `bun check`. |
| Owner Linux-packaging decision, November 8, 2026 | CI must generate both Flatpak and `.deb` packages for the Linux client. |
| Owner mandatory-cleaning decision | Hall closes to all customers every game day from 03:00 to 05:00 for cleaning, lasting five real minutes while available. Players use the interval for reviewing the past day and planning. Supersedes around-the-clock trading. |
| Owner ingredient-substitution decision | Most ingredients should have a cheaper or more readily available substitute that slightly reduces quality. Product mappings, owner policies, quantity conversions, and small penalty values above are proposed defaults. |
| Owner dietary-demand decision, November 8, 2026 | Incorporate varying dietary needs into customer choice, excluding incompatible dishes such as nonvegetarian meals for vegetarian diners. Profile definitions, weights, composition rules, and shared-course carbohydrate limits above are proposed defaults. Model eating requirements directly; diabetes is not equated with a mandatory keto diet. |
| Owner drink addition, November 8, 2026 | Add one cuisine-reflecting drink to each of the twenty cuisines, optionally ordered alongside the main dish. The catalog becomes 100 recipes: 60 savory, 20 dessert, and 20 drink. Drink selections, independent unlocks, same-stall checkout, joint tray fulfillment, and scoring details above are proposed defaults; earlier 80-recipe counts describe the pre-drink catalog. |
| Owner UX/onboarding/responsive decision, November 8, 2026 | Use the business overview with live hall context as the owner's default. Incorporate onboarding transparently into ordinary play without an explicit tutorial; make the UI usable on smartphone screens and take advantage of larger desktop displays. Navigation, layout ranges, contextual guidance, and qualification targets above are proposed design details. |
| Owner restaurant-license decision | Successful staff shifts offer visitors the opportunity to apply for a restaurant license, with applications listed for seed/admin approval. Success criteria, sponsorship, application lifecycle, and race handling above are proposed defaults. |
| Owner Indigenous cuisine addition, November 10, 2026 | Add Haudenosaunee, Diné (Navajo), Lakota, and Coast Salish to the launch roster. The existing five recipes per cuisine bring the total to 24 cuisines and 125 recipes. Specific menus, ingredients, and map footprints remain proposals. |
| Owner Māori cuisine addition, November 10, 2026 | Add Māori as the twenty-fifth cuisine, retaining three savory recipes, one dessert and one drink per cuisine (125 recipes total). Dish choices are the game adaptations described in the menu notes. |
| Owner execution-mode decision, November 11, 2026 | Servers are required only for multiplayer. Single-player runs locally/offline and pauses while closed; no wall-time catch-up is charged. Offline implementation and local storage/runtime qualification remain outstanding. |
| Owner row-of-halls decisions, November 13, 2026 | The hall becomes a row of ten square rooms of up to 15 stalls with tables in the centre, each with its own entrance; doorways stay shut until the next room is in use, which happens once every spot of one class is taken in the open rooms; quality is tied to position; the scene draws about one room at a time. A new hall starts with no computer-run restaurant on a prime spot. A class's rent rises as its availability falls, replacing fixed tiers. Position mapping, opening details, rent formula and tuning are proposed; see [Rooms](#rooms) and [Scarcity rent](#scarcity-rent). |

The PDF's final “complete specification” responses do not replace the earlier decisions or provide a complete working implementation. Several code blocks are visibly clipped. This document does not adopt their claims of guaranteed shutdown persistence, independently rounded customer allocations, repeated ingredient deductions, permanent prestige benefits, or unqualified local-runtime claims. It supplies explicit contracts for those areas instead.

Official technical references were checked on November 7, 2026: [Phoenix Channels](https://hexdocs.pm/phoenix/channels.html), [Elixir GenServer](https://hexdocs.pm/elixir/GenServer.html), [Render WebSockets](https://render.com/docs/websocket), and [Tauri macOS signing](https://v2.tauri.app/distribute/sign/macos/). Exact dependency versions and deployment settings should be selected and verified during implementation.

The architecture document retains references to [Microsoft's pattern guidance](https://learn.microsoft.com/en-us/azure/architecture/patterns/event-sourcing), [Elixir EventStore](https://hexdocs.pm/eventstore/EventStore.html), [Commanded event handlers](https://hexdocs.pm/commanded/events.html), and [PostgreSQL locking](https://www.postgresql.org/docs/current/explicit-locking.html). The proposed adapter and performance targets are Feud Hall design choices, not existing implementation results.

Culinary references for the proposed regional selections: [Incredible India on Punjabi/Mughlai food in Jalandhar](https://www.incredibleindia.gov.in/en/punjab/jalandhar/a-feast-for-the-senses), [Chandigarh dishes](https://www.incredibleindia.gov.in/en/chandigarh), and [Chennai cuisine](https://www.prod.incredibleindia.gov.in/content/incredible-india-v2/en/destinations/chennai/food-and-cuisine.html); recipe authors' [vegetarian mapo tofu](https://www.chinasichuanfood.com/vegetarian-mapo-tofu/comment-page-1/) and [kung pao chicken](https://www.chinasichuanfood.com/kung-pao-chicken/); [mushroom cheung fun](https://usa.lkk.com/en/recipes/mushroom-cheung-fun), [Cantonese white-cut chicken](https://www.madewithlau.com/recipes/white-cut-chicken), and [char siu](https://www.madewithlau.com/recipes/char-siu-chinese-bbq-pork). These inform dish names and culinary inspiration; quantities, equipment capabilities, work times, costs, and quality balance are game-design proposals.

Additional culinary inspiration: the Moroccan National Tourist Office's [couscous and tagine reference for part of the Berber starter assortment](https://visitmorocco.com/en/travel-info/food-drinks); Ethiopian Airlines' [injera, wot, and doro wat overview](https://www.ethiopianairlines.com/en-hk/flights-to-addis-ababa); PROMPERÚ's [Lima dishes](https://www.peru.travel/news/peru-conquers-canada-and-awakens-the-world-a-destination-that-has-it-all) and [regional dishes including papa a la huancaína](https://www.peru.travel/es/noticias/peru-refuerza-su-presencia-internacional-en-la-vitrina-turistica-anato); GoTürkiye's [lentil soup guide](https://goturkey.goturkiye.com/the-delicious-starters); Vietnam Tourism's [bánh mì recipe booklet with a tofu option](https://vietnam.travel/sites/default/files/2021-02/Recipes_booklet_F1.pdf) and [phở/bún chả guide](https://vietnam.travel/things-to-do/cuisine-gateway-hanoi%E2%80%99s-culture/); Indonesia's tourism board on [Indonesian dishes](https://www.indonesia.travel/content/dam/indtravelrevamp/upload-booklet/Indonesia%20Spice%20Up%20The%20World.pdf); and the Korea Tourism Organization's [bibimbap description](https://english.visitkorea.or.kr/svc/sp/food/ext/special_view.do?menuSn=913&vcontsId=178062) and [vegetarian ingredient considerations](https://english.visitkorea.or.kr/svc/contents/infoHtmlView.do?vcontsId=158975). These references inform inspiration only; the proposed vegetarian variants, portion sizes, station assignments, timing, and balance still require content review.

Persian menu inspiration: The Caspian Chef's [adas polo](https://thecaspianchef.com/2020/02/adas-polo-turmeric-rice-with-lentils/), [ash reshteh](https://thecaspianchef.com/2020/04/ash-reshteh-persian-noodle-soup/), [zereshk polo](https://thecaspianchef.com/2020/01/zereshk-polo-saffron-barberry-rice-braised-chicken/), and [Persian pantry guide](https://thecaspianchef.com/2022/07/the-persian-pantry/). The starter is an explicitly vegetarian game variant; the proposed menu retains the same automatic preparation/finishing and content-review requirements as other cuisines.

Brazilian and Colombian menu inspiration: Visit Brasil's [Minas dishes including frango com quiabo](https://www.feel.visitbrasil.com/en/minas-is-plentiful-a-tour-of-bhs-markets) and [moqueca cooking experience](https://www.feel.visitbrasil.com/aula-de-culinaria-baiana/); Colombia Travel's [arepas and regional dishes](https://colombia.travel/en/node/4378), [ajiaco description](https://colombia.travel/es/informacion-practica/acerca-de-colombia), and [patacones](https://colombia.travel/en/best-places-colombia-taste-colombian-food). Vegetarian starter variants and meal-size combinations are explicit game proposals; all ingredient bills, work times, freshness limits, and costs require the same content validation as the existing recipes.

Dessert inspiration includes JNTO's [dorayaki overview](https://www.japan.travel/en/blog/japanese-desserts-to-try/), the Hong Kong Tourism Board's [egg tarts and traditional desserts](https://www.discoverhongkong.com/eng/food-and-drink/must-try-traditional-hong-kong-desserts.html), the [Palestinian food guide's knafeh description](https://visitpalestine.ps/travel-information/food-and-dining/) and [Jordan's tourism food guide](https://edutravel.visitjordan.com/en/page/79/Food-and-Drinks), The Caspian Chef's [sholeh zard](https://thecaspianchef.com/2020/10/sholeh-zard-saffron-and-rosewater-rice-pudding/), Pailin Chongchitnant's [mango sticky rice](https://hot-thai-kitchen.com/mango-sticky-rice/), a recipe author's [himbasha](https://ethiopian-food.org/ambasha-himbasha-recipe/), PROMPERÚ's [picarones](https://www.peru.travel/es/inspirate/picarones-historia-y-preparacion-del-tradicional-postre-peruano), Türkiye's Ministry of Culture and Tourism on [tahin helvası](https://usak.ktb.gov.tr/TR-295580/tahin-helvasi-tahini-halva.html), Vietnam Tourism's [chè chuối](https://vietnam.travel/node/1668), Indonesia Travel's [klepon](https://www.indonesia.travel/us/en/travel-ideas/gastronomy/cari-takjil-buka-puasa-6-kudapan-khas-indonesia-ini-mudah-dicoba), Korea Tourism Organization's [hotteok](https://english.visitkorea.or.kr/svc/contents/contentsView.do?vcontsId=251506), Olivia Mesquita's [brigadeiro](https://www.oliviascuisine.com/traditional-brigadeiros/), and Colombia Travel's [obleas](https://colombia.travel/es/node/4305). The game uses proposed individual portions and compressed production steps; these sources do not establish game timing, prices, or balance.

Cuisine-scope revision references: a Kabyle community's [tikourbabine recipe](https://kabyle.com/cuisine/couscous-aux-tripes-taasbant-tikourbabine) and recipe author Samar's [semolina-dumpling preparation](https://www.mesinspirationsculinaires.com/article-osbane-kabyle-tikourbabine-boulettes-de-semoule-berberes.html) inform the Berber savory proposal, with an explicitly vegetarian game variant. Samar's [baghrir recipe](https://www.mesinspirationsculinaires.com/article-baghrir-algerien-112994594.html) informs the category's semolina-pancake dessert, alongside its shared Maghrebi traditions. Nigeria's National Institute for Cultural Orientation [cuisine inventory](https://nico.gov.ng/cuisines-in-nigeria/) and [Nigerian embassy food-culture publication](https://nigerianembassythehague.nl/wp-content/uploads/2023/11/Netherlands-Food-Cuisine-Culture-Final-print-version_compressed.pdf) inform Yoruba selections, including amala, efo riro, and moi moi; its vegetarian bean dishes use compatible stocks and seasonings. A recipe author's [puff-puff listing](https://sisiyemmie.com/category/recipe) informs the Yoruba dessert/snack proposal without claiming exclusive ownership of that shared food. The [Tamil Nadu visitor brochure](https://www.cgijoburg.gov.in/pdf/VTN_Visitor%20Brochure_6Pages.pdf) supports the retained Tamil inspirations. Dessert/snack placement, compressed work, recipe variants, prices, and ingredient mappings remain proposed content requiring review.

Javanese starter inspiration: Indonesia's cultural-heritage register lists [Pecel Madiun](https://budaya.data.kemdikbud.go.id/wbtb/objek/AA001669) in East Java. The vegetarian rice meal, ingredient bill, compressed preparation, and balance are game-content proposals.

Drink inspiration: Incredible India's [Punjabi lassi](https://www.incredibleindia.gov.in/en/punjab/ludhiana) and [Chennai filter coffee](https://www.prod.incredibleindia.gov.in/content/incredible-india-v2/en/destinations/chennai/filter-coffee.html); Japan's agriculture ministry on [sencha](https://www.maff.go.jp/e/policies/market/dento_syoku/bunrui/inryou.html); the Australian Consulate-General's account of [Chengdu teahouses and jasmine tea](https://chengdu.china.embassy.gov.au/cxdu/hopblog30.html); and Hong Kong Tourism Board on [Hong Kong-style milk tea](https://www.discoverhongkong.com/eng/place-to-go/travel.guide-lan-fong-yuen.html). These inform proposed portions and regional pairings, not exclusive origins or game balance.

Further drink references: Maureen Abood's [mint-lemonade listing](https://maureenabood.com/category/all-recipes/cocktails-and-drinks/page/2/), chef recipes for [doogh](https://www.bonappetit.com/recipe/doogh), the Moroccan National Tourist Office's [mint tea](https://www.visitmorocco.com/en/blog/time-moroccan-tea), Ethiopia's embassy on [coffee culture](https://ethiopianembassy.be/?page_id=20297), PROMPERÚ's [chicha morada](https://www.peru.travel/es/inspirate/chicha-morada-bebida-prehispanica-de-origen-peruano), GoTürkiye's [tea guide](https://cdn.goturkiye.com/gastro-v2/tea-rota.pdf), Vietnam Tourism on [cà phê sữa đá](https://vietnam.travel/things-to-do/taste-vietnam-story-behind-its-beloved-coffee-culture/), Central Java's [wedang jahe product record](https://pindah.jatengprov.go.id/inovasi/detail/862), Sue Pressey's [boricha](https://mykoreankitchen.com/korean-barley-tea-boricha/), the Italian espresso institute's [espresso definition](https://www.espressoitaliano.org/files/File/istituzionale_inei_hq_en.pdf), a recipe author's [cafezinho](https://tastyrecollections.com/brazilian-coffee-recipe/), Nigeria's embassy [food-culture publication including zobo](https://nigerianembassythehague.nl/wp-content/uploads/2023/11/Netherlands-Food-Cuisine-Culture-Final-print-version_compressed.pdf), and Erica Dinho's [aguapanela](https://www.mycolombianrecipes.com/es/aguapanela-o-agua-de-panela/). The proposed catalog uses non-alcoholic, individual game portions, paid ingredients, compressed order-bound work, and independently validated dietary facts; cultural service traditions do not add unbounded production time or free refills.

Additional drink references: Rick Bayless's [horchata menu](https://www.rickbayless.com/wp-content/uploads/2024/04/XSM_4424.pdf) and the Siam Tea Room's [Thai tea menu](https://www.thesiamtearoom.com/resourcefiles/pdf/str-menu-bkkqp.pdf) support those proposed beverage choices. Full game recipes and dietary declarations still require authored, validated content.
