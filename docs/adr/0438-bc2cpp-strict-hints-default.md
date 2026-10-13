# 0438. bc2cpp: strict hints are the default

Date: 2026-10-13

## Status

Accepted. Amends ADR 0419 (the default).

## Context

ADR 0419 made the strict hint tier opt-in. ADR 0428 then verified it on real RPG2000/2003 workloads: 78 runs on the
full sealed build (30 forced sites) and 78 on the hot-only build (36 sites), on Nepheshel206 and mtf-meido-action, with
0 hint violations and 0 verify aborts. The remaining decision was the default.

## Decision

- Unset or empty `BC2CPP_STRICT_HINTS` selects `1`: the receiver-hint families `typed`, `element`, `ivar_accessor`,
  `mono_embed`. `0` selects no family and is the byte-identical baseline. `1`, `all` and comma lists are unchanged.
- The reviewed gate (`STRICT_HINTS_REVIEWED`) still aborts a build on an unreviewed forced site, unless
  `BC2CPP_STRICT_HINTS_UNREVIEWED=allow`.
- The stale-entry rule is no longer applied by the build gate. `STRICT_HINTS_REVIEWED` is the union of the full and
  hot-only runs, so one run cannot prove an entry stale. `strict_hints_reviewed_check` still holds the union exact
  over both runs.

## Consequences

- A wrong hint in a shipped closed-world build now raises `BC2cppHintViolation` at the site, not a silent by-name
  dispatch. The 19 forced sites that no workload entered (ADR 0428) are not exercised, so a wrong hint there would
  surface in play, not in verification.
- The full wio closed world now forces 41 sites: `bc2cpp_send(M` falls from 1,956 to 1,916 in the shipped C++.
- `BC2CPP_STRICT_HINTS=0` restores the previous output; `strict_hints_check` checks both settings.
