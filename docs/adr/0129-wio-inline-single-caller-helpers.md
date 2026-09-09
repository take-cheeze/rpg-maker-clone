# 129. Fold a handful of low-use-count helpers into their call site, for wio only

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

### Expanded to methods with 2-3 real callers

Since this mechanism never touches the checked-in source at all, the
`scripts/**` test-coverage blocker above cannot recur regardless of which
method is picked -- `scripts/**` only ever sees the untouched original.
That freed up a second, larger candidate pool the first pass deliberately
left alone: methods with exactly 2 or 3 real callers within the 14-file
wio `rbfiles` list (395 of them). Inlining one of these means *duplicating*
its body at every call site instead of removing one irep node outright, so
whether it is still a net win depends entirely on the body's own shape --
checked by hand-testing each candidate (inline, recompile, compare), not
assumed from its byte size:

- **Straight-line expressions/one-line delegations duplicate cheaply and
  win**: `valid_move_freq` (a one-line ternary, 3 callers) saved 55 bytes;
  `item_cured_states` (a one-line delegation to `item_state_ids`, 2
  callers -- inlining it here means redirecting both callers to call
  `item_state_ids` directly, not copying any real logic) saved 80 bytes;
  `numpad_direction`/`continuous?`/`frame_dir` (`self.`-module one-liners on
  `Game::EventGraphic`, called from both a bare same-module site and an
  externally-qualified one) saved 69/19/39 bytes respectively -- smaller
  margins here since one call site's own constant requalification tax
  partly offsets the other's savings, but real and positive in every case,
  measured per file and summed.
- **Anything with its own loop or branch chain duplicates expensively and
  loses**: hand-tested and rejected on real numbers, not guessed --
  `lower_index` (an if/elsif chain, 3 callers, self_bytes 144) cost +100
  bytes; `quads_from_quarters` (a nested `2.times` loop building an array,
  2 callers) cost +71; `kana_step_col` (a `loop do...end` with an array
  lookup, 2 callers) cost +14. All three were left alone.
- **Foreign-receiver call sites rule out most of the remaining pool
  outright**: `shown?`, `moving?` (one call site uses `&:moving?`, not
  even a plain dot-call), `reset_frame_steps`, `map_step_damaged?`,
  `shaking?` and `class_name` all have at least one call site on a
  receiver other than `self` (`pic.shown?`, `@state.screen.shaking?`,
  `@interpreter.reset_frame_steps`, ...) -- inlining an ivar-touching
  method's body into a call on a *different* object is not achievable by
  source substitution at all, so these were never tested, just excluded
  the moment the receiver check failed.

### What was verified

- The rewrite script's own output diffed directly against the exact
  hand-verified before/after text for all four touched files -- identical.
- All four rewritten copies pass `mrbc -c` (syntax) cleanly.
- `git status` on `mruby-rpg2k/mrblib/` after running the rewrite script:
  empty -- the real source is provably untouched.
- Every candidate's net effect (win or loss) was measured with a real
  `mrbc --remove-lv` compile before being included or rejected -- none of
  the duplication-cost numbers above are estimated.
- **Real whole-gem measurement**: compiled `mruby-rpg2k`'s exact wio-shaped
  `rbfiles` list with `mrbc --remove-lv` (matching this board's real
  flags), once with the four original files, once with the four rewritten
  copies swapped in: **477,860 -> 477,133 bytes (727-byte reduction)** for
  all eleven methods combined (the original six plus the five from the
  2-3-caller expansion).
- Repo-wide grep (both `mrblib/**` and `scripts/**`) for every one of the
  eleven method names, confirming no other real caller exists anywhere.

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

- A real, if modest, ~727-byte flash win for wio, at zero behavioural
  change everywhere else and zero loss of test coverage anywhere --
  `scripts/rpg2k_render_check.rb` and friends keep exercising the full,
  original definitions on every target.
- This is deliberately not a general inliner and not something to extend
  mechanically: the 2-3-caller pool alone was 395 methods, and only 5
  survived hand-testing -- most fail on a foreign receiver (checkable by
  inspection) or a net-negative duplication cost (checkable only by really
  compiling both versions). Any further candidate, at any caller count,
  needs the same by-hand receiver check plus a real before/after compile,
  not a blanket re-run of either scan.
- desktop/psp/wasm/android builds are entirely unaffected -- they never run
  `wio_strip_inline_helpers` (gated on `build.name == 'wio'`) and keep
  compiling the real, unmodified source files directly.
