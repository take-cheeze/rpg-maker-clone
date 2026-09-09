# 129. Fold a handful of single-caller helpers into their call site, for wio only

Date: 2026-09-09

## Status

Accepted

## Context

`mrbc` has no inliner of its own -- checked directly in `mrbgems/mruby-
compiler/core/codegen.c`, no cross-method inlining exists anywhere. Every
`def`, no matter how many times (or how few) it is called, always gets its
own irep node: a 10-byte header plus its own `iseq`/`pool`/`syms` blocks,
none of it shared or deduplicated across scopes (confirmed earlier this
series: even a symbol name used in both a method and its one caller is
stored twice, once per scope).

A scan of the wio-relevant `mruby-rpg2k/mrblib` Ruby (the 14-file `rbfiles`
list `mrbgem.rake`'s existing exclusions already leave) found 669 of 1,552
methods (43%) with exactly one real call site in that source. Hand-testing
a few by literally inlining them and recompiling confirmed the effect is
real -- `bush_opacity` (no external symbol references) saved 101 bytes,
more than its own 45-byte size, once its call site's own `OP_SEND` and
symbol were counted too.

**The naive "669 candidates" estimate does not survive contact with
`scripts/*.rb`.** Attempting this as a general, automatic transform (delete
each single-mrblib-caller method, inline its body) found the real blocker
immediately: `scripts/rpg2k_render_check.rb`'s own CRuby-based regression
checks call several of these exact methods directly, by name, to test the
formulas they implement --

```ruby
check 'the sunken rows draw at half the opacity, rounded up' do
  eq 128, CS.bush_opacity(255)
  eq 128, CS.bush_opacity          # tests the default-argument behaviour
  ...
end
check 'message palette swatches form a 10x2 grid from y=48' do
  eq [0, 48], MP.cell_origin(0)
  ...
end
```

and `scripts/export_nano7_map.rb` calls `Game::ChipsetLayout.anim_c`
directly for its own tile-animation export. An earlier "single mrblib
caller ⇒ safe" scan never checked `scripts/` at all -- the identical blind
spot ADR 0128's own CI failure already exposed for `game/lsd_io.rb`, just
not caught by CI this time since the change was never pushed. Deleting
these methods from the checked-in source would silently break real
regression coverage (grid non-overlap, opacity edge cases) that has
nothing to do with wio.

## Decision

Keep every definition exactly as-is in the checked-in source -- every
target, including wio at dev/test time, keeps the full, directly-testable
method. Fold only a small, hand-picked and hand-verified set of six
(`bush_opacity`, `cell_origin`, `shadow_origin`, `anim_c`, `invalidate_items`,
`drive_autostart_cascade`) into their one real *engine* call site in a
**wio-only build-time rewritten copy**, the same mechanism ADR 0119's
`wio_strip_debug_rbfiles`/`strip_wio_debug_output.rb` already established
for stripping `$stderr.puts` calls: a Ripper-verified rewrite of a copy
under `spec.build_dir`, never the real file, wired in as
`wio_strip_inline_helpers` (`build_config.rb`) called from
`mruby-rpg2k/mrbgem.rake` just before `wio_strip_debug_rbfiles`.

`strip_wio_inline_helpers.rb` expresses each change as either a line-range
deletion (a first-line/last-line marker pair, checked to appear exactly
once each and to span exactly the expected line count) or an exact-text
substitution -- and refuses to touch anything if a marker or line count no
longer matches, rather than silently reapplying a stale patch to source
that has since changed. All six were picked by hand after checking, not
assuming, that their receivers make this safe:

- `bush_opacity`/`cell_origin`/`shadow_origin`/`anim_c`: `self.`-only module
  methods (`Game::CharSet`, `Game::MessagePalette`, `Game::ChipsetLayout`)
  called as `Module.method(...)` from their one real caller, with every
  internal constant reference (`COLS`, `CELL`, `SHADOW_X`, ...) requalified
  at the call site -- `cell_origin`'s `[(idx % COLS) * CELL, ...]` becomes
  `(idx % Game::MessagePalette::COLS) * cell` (reusing the `cell` local the
  caller already has, better than the naive full-requalification a
  mechanical rewrite would produce).
- `invalidate_items`/`drive_autostart_cascade`: plain instance methods
  called bare (implicit `self`) from within the exact same class, so their
  `@ivar`/sibling-method references carry over unchanged.

Every other real call site (repo-wide grep, all of `mrblib/**` and
`scripts/**`) was re-checked before this decision, not just `mrblib/**` --
`scripts/export_nano7_map.rb`/`rpg2k_render_check.rb`/`rpg2k_scene_check.rb`
all keep calling the six methods normally, against the untouched real
source, exactly as before.

### What was verified

- The rewrite script's own output diffed directly against the exact
  hand-verified before/after text for all four touched files -- identical.
- All four rewritten copies pass `mrbc -c` (syntax) cleanly.
- `git status` on `mruby-rpg2k/mrblib/` after running the rewrite script:
  empty -- the real source is provably untouched.
- **Real whole-gem measurement**: compiled `mruby-rpg2k`'s exact wio-shaped
  `rbfiles` list with `mrbc --remove-lv` (matching this board's real
  flags), once with the four original files, once with the four rewritten
  copies swapped in: **477,860 -> 477,395 bytes (465-byte reduction)** for
  these six methods combined.
- Repo-wide grep (both `mrblib/**` and `scripts/**`) for every one of the
  six method names, confirming no other real caller exists anywhere.

### What was not verified

- No real `MRUBY_TARGET=wio rake` build (same unrelated sandbox gap as ADR
  0128: `mruby-lcf`'s own `cp932_table` build-time codegen needs an env var
  this sandbox lacks) -- the rake wiring (`wio_strip_inline_helpers` in
  `build_config.rb`, called from `mrbgem.rake`) mirrors
  `wio_strip_debug_rbfiles`'s already-proven-in-production shape exactly,
  changing only the script path and output directory, but was not itself
  exercised by a real rake invocation.
- Chaining `wio_strip_inline_helpers` before `wio_strip_debug_rbfiles`
  means the *second* step's own `rel = src.sub(spec.dir prefix)` no longer
  matches (the first step's output already lives under `build_dir`, not
  `spec.dir`), so its output path nests more verbosely than
  `wio_strip_debug_rbfiles` produces on its own -- functionally harmless
  (`FileUtils.mkdir_p` handles arbitrarily nested paths), but not the clean
  single-level directory structure debug-stripping alone gets.

## Consequences

- A real, if modest, ~465-byte flash win for wio, at zero behavioural
  change everywhere else and zero loss of test coverage anywhere --
  `scripts/rpg2k_render_check.rb` and friends keep exercising the full,
  original definitions on every target.
- This is deliberately not a general inliner and not something to extend
  mechanically: the remaining ~663 "single mrblib caller" candidates found
  by the original scan were not re-audited against `scripts/**`, and this
  ADR's own finding is that a fair number of exactly this "looks like an
  internal helper" shape turn out to be directly unit-tested. Any further
  candidate needs the same by-hand receiver/test-coverage check this ADR's
  six got, not a blanket re-run of the naive scan.
- desktop/psp/wasm/android builds are entirely unaffected -- they never run
  `wio_strip_inline_helpers` (gated on `build.name == 'wio'`) and keep
  compiling the real, unmodified source files directly.
