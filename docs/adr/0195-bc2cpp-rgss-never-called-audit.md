# 195. Auditing mruby-rgss-compiled's "never called" list: zero safe, two real diagnostic blind spots found

Date: 2026-09-22

## Status

Accepted

## Context

docs/adr/0193 deliberately excluded `mruby-rgss-compiled`'s own owners
wholesale from registration pruning: `RGSS::Sprite`/`Window`/`Plane`/
`Bitmap`/`Audio`/`Graphics`/`Input` (plus bare `Array`/`StringIO`) are the
real RGSS scripting API a downstream game's own bundled "stock scripts"
call, invisible to this project's own static analysis. The natural
follow-up question: could that blanket exclusion be narrowed with real
evidence -- this project's own `docs/rpgxp-rgss-api-gap.md`/
`docs/rpgvx-rgss-api-gap.md` real-usage surveys -- rather than left as
"never touch this gem"?

## Decision

Audited, individually, every one of bc2cpp.rb's own 29 "never called"
entries for `mruby-rgss-compiled` against real evidence. **Zero qualify for
pruning.** The four criteria and a condensed per-entry verdict (which
criteria clear each entry) are recorded in
`tools/bc2cpp/rgss_confirmed_unused.rb` (a real, checked-in file exporting
an intentionally empty `Set`, kept so the investigation is not repeated
from scratch by a later round, and so a genuinely new candidate has a
documented bar to clear).

Every entry fell into one of four buckets: a real call site this project's
own `NATIVE_SRCS` scan cannot see (this repo's top-level `src/*.cxx` is
never scanned, and one call site uses a runtime-chosen method name
`extract_native_call_names`' regex could never match regardless); a real
call site in a sibling maker gem's own mrblib (`mruby-rpgxp`/`mruby-rpgvx`/
`mruby-wolf`/`mruby-mv`/`mruby-mz` are never part of
`closed_world_mrblib_srcs`, despite being real, shipped consumers of the
RGSS API in this project's own tree, not merely hypothetical downstream
games); a documented, measured-used real RGSS accessor whose "never
called" half is a getter paired with a doc-confirmed-used setter (reading
before writing, or an in-place-mutate idiom this project's own source
comments confirm is the real, only way a script sets that property, e.g.
`Tilemap#autotiles`'s `autotiles[i] = ...` -- "there is no `autotiles=` in
RGSS"); or an owner in `BC2CPP_WIRED_EMBEDDINGS`, where a hand
`register.cxx` line is provably redundant with the generated
`bc2cpp_register_owner_methods` call and removing it is a **confirmed
no-op**, not merely a risk -- verified directly this session by removing
`RGSS::ErrorReport.singleton#installed?`'s own hand registration (the one
entry with genuinely zero call evidence found anywhere) and re-running
`scripts/bc2cpp_wired_embedding_check.rb`, which still reported it
installed. The edit was reverted.

### Two real gaps in bc2cpp.rb's own reachability scan, found by this audit

Neither is new work this ADR does -- both are flagged here as findings for
whoever next touches `tools/bc2cpp/bc2cpp.rb`'s "never called" diagnostic
or `tools/bc2cpp/compiled_gems.rb`'s `closed_world_mrblib_srcs`/
`core_native_srcs`:

1. `NATIVE_SRCS` (as every current consumer of this diagnostic constructs
   it -- `wio_registered_methods.rb`, `bc2cpp_wired_embedding_check.rb`,
   `never_called_registrations.rb`) never includes this repository's own
   top-level `src/*.cxx` (the executable's own entry points and CLI
   probes), only `mruby-rgss/src/*.cxx` and the core/external gem native
   sources. Real `mrb_funcall` call sites exist there.
2. `closed_world_mrblib_srcs` scans only `mruby-rpg2k`/`mruby-lcf`/
   `mruby-rgss`'s own mrblib -- never `mruby-rpgxp`, `mruby-rpgvx`,
   `mruby-wolf`, or `mruby-mv`/`mruby-mz` (`mruby-mvjs`'s own mrblib), each
   a real, shipped consumer of the RGSS API this project builds today, not
   a hypothetical external game. A name "never called" by this diagnostic
   only ever means "never called by RPG2000/2003's own engine code" --
   never "never called by anything this repository ships."

Neither gap affects docs/adr/0193's own two real prunings
(`Game::Character#front_tile`, `LCF::Database#maker`): both are RPG2000/
2003-internal classes under namespaces no other shipped maker engine in
this tree references, and docs/adr/0194's own def-deletion tier already
runs a separate, genuinely whole-repository text search
(`scripts/bc2cpp_def_deletion_safety_check.rb`) before deleting anything
outright, which is not scoped to `closed_world_mrblib_srcs` at all and
would catch either gap if it were ever live for a real candidate. Fixing
either gap in bc2cpp.rb's own scan is real, separate follow-up work,
useful mainly for keeping the "never called" *diagnostic itself* honest,
independent of anything this ADR's own audit needed it for.

## Consequences

- `mruby-rgss-compiled`'s owners stay wholesale-excluded from
  `tools/bc2cpp/never_called_registrations.rb`'s pruning, unchanged from
  docs/adr/0193 -- this audit is a real, negative confirmation that the
  original conservative scope was correct, not a reason to revisit it.
- A future round adding a genuinely new compiled method to
  `mruby-rgss-compiled` that later shows up as "never called" has a
  documented four-part check to run (`tools/bc2cpp/
  rgss_confirmed_unused.rb`'s own header) rather than starting from
  nothing, and a real place (`RGSS_CONFIRMED_UNUSED`) to record a genuine
  future exception if one is ever found.
- The two diagnostic-scan gaps above are flagged, not fixed, here.
