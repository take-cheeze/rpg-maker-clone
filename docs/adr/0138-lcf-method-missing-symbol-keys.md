# 138. Replace mruby-lcf's `method_missing` field access with real `Symbol` keys

Date: 2026-09-10

## Status

Accepted

## Context

`LCF::Array1D` (one parsed LCF record -- an Actor, Item, save-data chunk,
...), `LCF::Sections` (a multi-section file's section list) and `LCF::File`
(the `.ldb`/`.lmt`/`.lmu`/`.lsd` wrapper) all resolved dot-syntax field
access (`record.field_name`, `sections.section_name`, `file.hero`) via
`method_missing`, reflecting the call into a numeric chunk-id or
section-name lookup. An earlier scoping pass (docs/adr's own predecessor
investigation, not written up as its own ADR) found this is the one
genuinely irreducible reflection point left in the engine: the event
interpreter is already a static 127-arm `case`/`when`, `define_method` has
zero occurrences, and singleton classes are rare -- but which fields exist
on a given record is decided by schema.rb's runtime-loaded, externally-
authored game data, so *some* form of dynamic field access is real, not
incidental complexity.

`method_missing` is already the cheapest possible implementation of that
dispatch -- it costs no RAM on this target (bytecode is flash-resident),
so this was never about a RAM or flash win. It was raised as a
correctness fix instead: `method_missing`-based dot access silently
collides with any real method of the same name already reachable on the
object -- documented in AGENTS.md/ADR96/ADR102 as a live bug, `db.system`
resolving to `Kernel#system` under CRuby instead of the `system` LCF field,
because `method_missing` only fires when no real method already answers.
Real `Symbol`-keyed `[]` doesn't have this hazard: `db[:system]` can never
collide with anything.

A static-analysis scoping estimate (grep/AST-based) had put the call-site
count at roughly 1,400-2,000 across the engine, with no existing codegen
tooling to rewrite them, and ADR 129's own prior broad automated call-
site-rewrite attempt was a documented failure (wrong line numbers, symbol-
vs-call confusion, multi-line corruption) that led to ADR 131's narrower,
hand-verified approach instead. Given that history, a third attempt at a
blind, engine-wide static rewrite was judged too risky to attempt in one
pass.

## Decision

**Added real, `Symbol`-accepting methods alongside `method_missing`,
rather than replacing it outright**:

- `Array1D#[]`/`#[]=`/`#key?` all now accept a `Symbol` (resolved via the
  existing, already-memoized `sym2idx` schema lookup) in addition to a
  numeric chunk id.
- `Sections#[]`/`#key?` gained the same `Symbol` acceptance (`Sections`
  already exposed `@by_name` internally; this just makes it a real `[]`
  path instead of only a `method_missing` one).
- `LCF::File` gained real `#[]`/`#[]=`/`#key?` forwarding straight to
  `@root`. This closed a second, previously invisible gap: existing code
  already called `save[101]` / `save[22] = value` directly on `File`-
  wrapping objects (AGENTS.md's own documented workaround for the
  `db.system` collision), but `File` itself had no real `[]`/`[]=` of its
  own -- those bracket calls were *also* silently going through
  `method_missing`'s `@root.__send__` forwarding. Adding the three direct
  methods fixed this with zero call-site changes.

`method_missing`/`respond_to_missing?` were **kept** on `Array1D` and
`Sections` (not deleted) as an explicit safety net for any call site the
migration below did not reach, with a comment explaining why.

**Call-site discovery used dynamic instrumentation, not static analysis**
(the user's own suggestion mid-session, and a real methodological
correction from the static-scoping estimate above): temporarily logged
every real `method_missing` invocation's `caller_locations` inside all
three `method_missing` bodies, then ran every CRuby-executable test script
this repo ships (13 of `scripts/*.rb`; the 3 that need an unavailable
downloaded test-bed or a built native binary were confirmed to fail only
for that unrelated reason and excluded). This found **158 real call
sites** in the shipped engine -- an order of magnitude fewer than the
static estimate, and each one independently confirmed by actual
execution rather than a name-collision-prone text match:

- `mruby-rpg2k/mrblib/game/lsd_io.rb`: 151 (the LSD save-file loader/
  writer -- by far the largest concentration of real field-getter access)
- `mruby-rpg2k/mrblib/game.rb`: 6 (`Vehicle#load_movable`)
- `mruby-rpg2k/mrblib/scene/save_load.rb`: 1

A key invariant made the rewrite itself safe: `Array1D#method_missing`
begins with `raise args unless args.empty?`, so it can only ever be
triggered by a zero-argument **getter** call -- a setter (`record.field =
v`, dispatched as method `field=` with one argument) raises instead of
reaching this fallback. A first rewrite pass added setter-detection logic
anyway and, as a direct result, corrupted 3 lines by matching the *wrong*,
real, unrelated setter sharing a field name on the same line (`actor.exp
=`, `actor.skills =`, `actor.battle_commands =`). Reverted, and rewritten
using this invariant instead: every logged hit is guaranteed getter-only,
so the fix is a single per-(file, line, symbol) substitution
(`\.field\b` -> `[:field]`, with a negative lookahead skipping anything
already shaped like a setter) with no ambiguity to resolve.

Verified against the same 13 test scripts after the rewrite (all still
passing), then re-instrumented and re-ran to confirm the fix: hits in
shipped engine code dropped to zero. The 145 remaining hits all land in
`scripts/rpg2k_logic_check.rb` alone, a CRuby-only dev/test harness never
shipped to any real target, so no known call site was left un-migrated
inside the actual engine.

## What was verified

Beyond the 13 CRuby scripts (1,200+ checks total across them), the real
wio-target cross-build was rebuilt end to end with these changes and
confirmed to still boot:

- A full clean `MRUBY_TARGET=wio rake` (all 9 project mruby patches
  re-applied first) produced a real `libmruby.a` carrying the rewritten
  `lcf.rb`/`lcf_file.rb`/`lsd_io.rb`/`game.rb`/`save_load.rb`.
- A real `pio run -e wio_rgss_boot_heapdbg_ram` link succeeded (the
  non-widened `wio_rgss_boot` env still overflows real flash by 684,536
  bytes -- consistent with ADR 135/136's own baseline; RAM/flash fit is
  unrelated, already-tracked follow-up work, not something this change
  attempted to move).
- Booted the linked ELF under Renode with GDB breakpoints on both `abort`
  and the same post-`mrb_full_gc(M)` success line ADR 136 used: the
  success breakpoint hit cleanly, with `mrb_open_core`,
  `rpg_maker_init_shared_gems` and `rpg_maker_init_rpg2k_gem` (the exact
  call chain that defines every `Array1D`/`Sections`/`File` method
  touched here) all completing with no abort anywhere in the run.

## Consequences

- **The `db.system`-style collision bug (AGENTS.md/ADR96/ADR102) is fixed
  for every migrated call site**: `db[:system]` cannot collide with
  `Kernel#system` the way `db.system` could.
- **`method_missing` remains live** on `Array1D`/`Sections` as a
  deliberate safety net, not a leftover -- static analysis suggested up to
  ~2,000 call sites might exist engine-wide (e.g. in `battle.rb`/
  `battle_support.rb` paths, or scripts needing a downloaded test-bed this
  sandbox doesn't have), and dynamic instrumentation is bounded by what
  the available tests actually exercise. Any such site keeps working
  exactly as before; it just isn't collision-safe yet. Fully removing
  `method_missing` is a possible follow-up once/if broader test coverage
  (or a real downloaded test-bed) lets the same dynamic-instrumentation
  technique reach those paths too.
- **This session's own dynamic-instrumentation methodology is reusable**
  for any future `method_missing` (or similar reflection) migration in
  this codebase: cheaper and more precise than static grep/AST scoping,
  bounded only by test coverage, and the getter-only invariant this ADR
  found is specific to this one gem's contract, not a general rule --
  future migrations need to re-derive (or confirm) the equivalent
  invariant for whatever they touch.
- No RAM or flash change of note (a few hundred bytes either way from the
  method-body edits themselves) -- this was a correctness and API-clarity
  change, not a footprint one, consistent with the Context section's own
  reasoning for why `method_missing` was never a footprint target to
  begin with.
