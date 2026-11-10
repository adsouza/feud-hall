# ADR 0001: Full gameplay event sourcing from the first release

Status: adopted design direction; implementation qualification pending.

Decision date: November 7, 2026. Documentation reorganized November 8, 2026.

## Context

Feud Hall is a persistent shared economy with scarce resources, human and NPC
operators, paid visitor work, account admission, explicit clocks, and permanent
business histories. Lost replies, restarts, and concurrent actions must preserve
fair outcomes without repeating purchases, wages, invitations, or grants.

The owner requested full event sourcing while starting from scratch, if viable.
The planned pure decision/evolution core and shared atomic commit boundary fit
this approach. Recording complete domain facts from the beginning avoids a later
migration that cannot reconstruct missing historical decisions.

## Decision

Use full event sourcing for durable gameplay and account-entitlement state from
the first economic-core milestone. Immutable domain events in PostgreSQL are the
authority. Current state, ledgers, reports, and snapshots are derived; corrections
append explicit facts rather than silently rewriting accepted history.

Keep a modular monolith and shared atomic economic transactions. Selecting event
sourcing does not require a broker, independently deployed services, or eventual
settlement of money and stock. Protected credentials/contact values and durable
operational delivery/coordination records remain separate from the immutable
gameplay log.

The implementation contracts now live in [Feud Hall Architecture](../ARCHITECTURE.md#event-persistence),
including event scope, append consistency, projections, delivery, snapshots,
recovery, compatibility, and verification. This ADR records the choice and why;
implementation details should be maintained there.

## Alternatives considered

| Alternative | Assessment |
| --- | --- |
| Mutable current-state tables with an audit trail | Simpler initial storage and querying, but an audit trail may omit decisions needed to explain or reconstruct the complete economy. Retrofitting full history later would be difficult. |
| Event-source only finance or selected features | Reduces initial event/schema work, but leaves clocks, staffing, inventories, NPC decisions, and identity with separate authorities and incomplete replay. |
| Full domain event sourcing with derived current views | Selected for coherent reconstruction, permanent history, and deterministic verification; accepts the additional compatibility and operational work. |

Separate services, dedicated event infrastructure, and aggregate-per-process
frameworks are implementation options, not prerequisites of the selected approach.

## Benefits and costs

- Complete history supports explaining market allocation, resource losses, NPC
  behavior, account ancestry, and business failure.
- Rebuildable projections and deterministic replay support diagnosis, regression
  fixtures, and comparison of live, snapshot-tail, and genesis state.
- Events must capture complete outcomes and retain compatible schemas, evolution
  behavior, and versioned content for the lifetime of the history.
- Storage grows continuously. Replay, archival, backups, and recovery need measured
  budgets and maintained tooling; snapshots alone do not remove those obligations.
- Projections and external delivery introduce consistency/idempotency work. Replay
  must not send old mail or repeat gameplay rewards, and immutable history must
  exclude raw secrets and erasable contact values.

## Qualification and reconsideration

The internal slice has PostgreSQL event storage, crash recovery, and replay
coverage. Project C records append, storage, and recovery measurements for the
150-stall internal workload. [Project C capacity report](../superpowers/reports/2026-11-10-milestone-2c-capacity.md).
Release qualification covers the 450-session workload, recovery on the selected
server, and retained-history cost.
[Architecture qualification plan](../ARCHITECTURE.md#early-qualification-and-ongoing-tests).

If qualification fails, first measure and adjust event granularity, batching,
indexes, snapshots, and projector placement. If the costs remain unacceptable,
record the evidence and explicitly revisit this decision with the owner before
changing the persistence direction. Do not introduce a second mutable authority
or weaken atomic economic settlement as an undocumented workaround.
