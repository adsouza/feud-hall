# Feud Hall

![Feud Hall — six colorful restaurant stalls in a shared food hall](assets/branding/feud-hall-social.svg)

A persistent multiplayer business simulation about running restaurants in a food hall.

The repository contains the design, artwork, and an Elixir/PostgreSQL backend
for the shared simulation. Milestone 2 is complete with the accepted local
150-stall measurement.
[Capacity report](docs/superpowers/reports/2026-11-10-milestone-2c-capacity.md).

See the [game design document](docs/GAME_DESIGN.md) for the gameplay, simulation rules, first-release scope, and acceptance criteria.

The [architecture document](docs/ARCHITECTURE.md) defines DDD boundaries, Clean Architecture, CQRS, AOP techniques, commands, event persistence, diagnostic logging, recovery, deployment, and verification contracts.

The [testing plan](docs/TESTING.md) defines formatting, Bun/Oxlint verification, property/mutation testing, CI gates, and local execution limits. The [deployment plan](docs/DEPLOYMENT.md) covers Render releases, recovery, and Linux/macOS packages.

The [event-sourcing ADR](docs/decisions/0001-event-sourcing.md) records the persistence decision, alternatives, tradeoffs, and qualification requirement.

The [artwork sources and export guide](assets/branding/README.md) include SVG icons, a wordmark, and a social/banner composition.

Coding agents should start with [AGENTS.md](AGENTS.md) for repository conventions and verification policy.

## Run the management game locally

Build the Svelte client, then start the Phoenix server against a dedicated local
PostgreSQL database. See [local setup](docs/DEPLOYMENT.md#local-management-game)
for configuration and initial owner seeding.
