# 0485. bc2cpp: NOMETHOD_REVIEWED stale check is off for full builds

Date: 2026-10-17

## Status

Accepted. Amends ADR 0226 (the stale-entry half of the NOMETHOD_REVIEWED gate).

## Context

ADR 0226's gate fails a build when a listed key has no site any more (stale), as well as when a site is unreviewed.
A hot-only build passes the stale half (it passes `stale: false`). A full build did not: six keys
(`Game::Interpreter#actor_operand -> exp`, `Game::State#to_lsd -> exp`, `Game::Troop#total_exp -> exp`,
`RPG2k::Scene::Map#step_parallel -> start`, `RPG2k::Scene::Menu#draw_status_exp -> exp`,
`RPG2k::Scene::StatusMenu#draw_gauges -> exp`) are sites in the per-gem probe (`nomethod_reviewed_probe.rb`), which
compiles each gem with only its own owners, but are not emitted by the whole-program build. Pruning them fails
the probe's unreviewed check, so the two views cannot both be satisfied by the list.

## Decision

The full build passes `stale: false` for NOMETHOD_REVIEWED. Unreviewed sites still fail every build. ProvenMiss's
stale check is unchanged.

## Consequences

- A full build no longer reports a listed key that the whole-program build does not emit. The list can therefore keep
  keys that are stale for the shipped build until the probe is changed to match the whole-program view.
- The probe and the build disagree about the six keys above. Resolving that (probe per-gem owners, or a union
  check) is still open.
