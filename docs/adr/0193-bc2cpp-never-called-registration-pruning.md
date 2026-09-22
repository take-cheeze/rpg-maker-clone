# 193. Pruning bc2cpp registration for compiled methods with zero call evidence

Date: 2026-09-22

## Status

Accepted

## Context

`tools/bc2cpp/bc2cpp.rb`'s own Step 6h has long computed a "never called"
diagnostic: of every method a `*-compiled` gem's own `register.cxx` installs
an AOT-compiled C++ override for, which ones have zero evidence of any call
site anywhere in the whole program's own bytecode (`collect_static_call_
target_names`) or in `NATIVE_SRCS` (`extract_native_call_names`)? Until now
this was print-only -- a "real candidate for deletion, not proof of it," per
its own comment -- surfaced every run but never acted on.

Separately, docs/adr/0143's real remeasurement (superseded by this session's
own fresh remeasurement the same day this ADR was written -- see the flash
numbers below) established that `RPGMAKER_BC2CPP=1`'s real flash cost on
`wio_rgss_boot` has grown substantially as coverage expanded (roughly 811.5%
of the 507,904-byte budget as of this session, up from 443.3% at 0143's own
measurement 10 days earlier). Every byte this AOT path can shed without a
correctness cost is worth taking, however small individually.

Acting on "never called" is not automatically sound, though. bc2cpp.rb's own
comment on the diagnostic already explains why: `mruby-rgss-compiled`'s own
owners (`RGSS::Sprite`/`Window`/`Plane`/`Bitmap`/`Audio`/`Graphics`/`Input`,
plus the bare `Array`/`StringIO` it also compiles for cross-gem
devirtualization reasons) are exactly the public scripting API surface a
downstream game's own bundled "stock scripts" call -- invisible to any
static analysis this tool can run. A "never called" name there is the
expected shape of a public API, not evidence of dead code. Only RPG2000/
2003's own internal engine classes (`Game::`/`RPG2k::`/`RPG2k3::`/`LCF::`)
have no such external-script layer at all: every real call site to one of
those has to originate from this project's own checked-in mrblib or
`NATIVE_SRCS`, both of which the existing diagnostic already covers
completely.

A second, independent hazard: `BC2CPP_WIRED_EMBEDDINGS` (compiled_gems.rb)
owners require *every* compiled entry point installed together, or an
interpreted fallback for just one method reads the ordinary `iv_tbl` while
its compiled siblings write an RData struct instead, and sees `nil` (the
exact bug class docs/adr/0139's own eighth-severity finding and the
`compiled_gems.rb` `EMBED_WIRED` comment describe). Removing a registration
from a wired owner, regardless of call evidence, is never safe.

A third, more mundane hazard: `tools/bc2cpp/wio_registered_methods.rb` (the
probe `strip_wio_bc2cpp_stubs.rb`/docs/adr/0144 uses to know which methods'
interpreted bytecode `def` is safe to delete from mrblib source) has always
assumed "bc2cpp.rb can compile this" implies "register.cxx actually
registers it" -- true by construction until now, since every gem's own
register.cxx has always been kept in lockstep with what compiles clean
(the registration-completeness batches, e.g. docs/adr/0190, exist
specifically to hold that invariant). Deliberately un-registering a
compiled-but-dead method for the first time breaks that assumption: if
`wio_registered_methods.rb` kept reporting such a method as "registered,"
`strip_wio_bc2cpp_stubs.rb` would delete its only remaining real
implementation (the interpreted bytecode `def`) for a live `NoMethodError`
regression.

## Decision

Turn the diagnostic into a real, conservatively-scoped elimination:

- **`tools/bc2cpp/never_called_registrations.rb`** (new) wraps bc2cpp.rb's
  own "never called" and "compiled entry points" stderr sections and adds
  the owner-safety filter: a namespace check (`Game::`/`RPG2k3?::`/`LCF::`
  only -- a namespace check, not a gem-name check, since `StringIO`/`Array`
  live in the same gems as genuinely-internal classes), never a
  `BC2CPP_WIRED_EMBEDDINGS` owner, never a `.singleton` owner (the same
  conservative scope `strip_wio_bc2cpp_stubs.rb` already uses, for the same
  DEFS/SCLASS-span-finding-is-out-of-scope reason).
- **`scripts/bc2cpp_prune_never_called_registrations.rb`** (new) removes
  the matching `mrb_define_method`/`mrb_define_private_method` line(s) from
  the real, checked-in `register.cxx` for `mruby-rpg2k-compiled` and
  `mruby-lcf-compiled` (never `mruby-rgss-compiled`: no owner it compiles
  ever clears the namespace filter, so there is never anything to remove
  there). A source-mutating tool run by hand, not a build step -- the same
  posture the registration-completeness batches already used, since a
  removed registration is worth a human/AI sanity read, not a silent
  automatic rewrite.
- **`scripts/bc2cpp_never_called_registrations_check.rb`** (new) is the CI
  regression guard: recomputes the same candidate set and fails only if one
  is *still* present in the real `register.cxx` (cross-checked against the
  actual file content, not just against what bc2cpp.rb could compile --
  otherwise it would fail forever, since bc2cpp.rb has no way to know
  register.cxx stopped calling a method it can still compile).
- **`tools/bc2cpp/wio_registered_methods.rb`** now excludes these same
  entries from its own `registered.tsv` output, closing the third hazard
  above: once a method's registration is gone, its interpreted bytecode
  `def` is its only real implementation, and `strip_wio_bc2cpp_stubs.rb`
  must leave it alone.

Removing a registration deliberately does **not** touch the method's own
mrblib source `def`. The AOT override is simply not installed any more; the
method falls back to the ordinary interpreted bytecode path, identical to
every other bc2cpp-uncovered method in the same class. This is what makes
the mechanism safe even against a static-analysis miss: if some call site
this tool's reachability scan cannot see (there should not be one, for a
`Game::`/`RPG2k::`/`LCF::`-owned method, per the Context section above, but
soundness here does not depend on that being watertight) does call the
method, it still works -- just interpreted rather than native, not
`NoMethodError`.

## Real measurement

Run for real against a full host `RPGMAKER_BC2CPP=1` build (this session):
exactly two candidates were both compiled and currently registered --
`Game::Character#front_tile` (`mruby-rpg2k-compiled`) and
`LCF::Database#maker` (`mruby-lcf-compiled`). Both removed.
`bc2cpp_wired_embedding_check.rb` still passes 100% on every wired owner
(untouched by this change) and `bc2cpp_never_called_registrations_check.rb`
is clean on both gems afterward.

Confirmed against a real `wio_rgss_boot` ARM cross-build and link
(`scripts/wio_bc2cpp_measure.bash`), before and after the prune:

- **Before** (this session's own fresh full-scope remeasurement, same day):
  bc2cpp flash-needed 4,121,836 bytes (811.5% of the 507,904-byte budget),
  RAM 41,464 bytes (21.1% of the 196,608-byte budget). Both symbols present
  in the real, linked memory map with real addresses (e.g.
  `Game__Character_front_tile_impl` at `0x000edffc`).
- **After**: bc2cpp flash-needed **4,121,648 bytes (still 811.5% to one
  decimal place, -188 bytes)**, RAM unchanged at 41,464 bytes. Both symbols
  now appear only in the linker map's own "Discarded input sections"
  listing (address `0x00000000`, `ld`'s marker for a section `--gc-sections`
  removed) -- confirmed absent from the real "Linker script and memory map"
  section specifically, not merely absent from a `grep` of the whole file.
  Baseline (no bc2cpp) is byte-for-byte unchanged either way, as expected --
  it never compiles either `register.cxx`.

Small in absolute terms -- two methods out of well over a thousand real
compiled entry points, and the board is still ~8x over its flash budget
either way -- but a real, measured, zero-risk reduction, and the
infrastructure (the reachability helper, the prune script, the regression
check) is reusable for every future round: as coverage keeps expanding
(docs/adr/0144 through 0192 and beyond), this is the mechanism that keeps
genuinely-dead AOT overrides from accumulating unregistered-but-still-worth-
checking-for cost again.

## Consequences

- `scripts/bc2cpp_never_called_registrations_check.rb` should be added to
  CI's static-checks group (alongside `bc2cpp_wired_embedding_check.rb` and
  its siblings) as a follow-up, so a later round that adds a registration
  for a name with no real call evidence is caught immediately rather than
  rediscovered by hand.
- The owner-safety scope is deliberately conservative (internal RPG2000/
  2003 engine classes only). Widening it -- e.g. to specific
  `mruby-rgss-compiled` methods a real, out-of-band audit of this project's
  own bundled "stock scripts" proves are never called by any of them --
  is real, separate follow-up work, not something this change attempts.
- This does not move the needle on `wio_rgss_boot` actually fitting its
  flash budget; the gem trimming (P2) and streaming asset loading (P3) work
  docs/adr/0007 already calls out remains the real path there. This is
  incremental hygiene on the AOT path specifically.
