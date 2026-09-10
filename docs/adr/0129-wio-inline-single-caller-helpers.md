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

### A validated rule for single-caller methods -- and a general-automation attempt that failed

Going back to single-caller (not 2-3-caller) methods with fresh eyes:
receiver-safety was already established for the "bare call within the same
class" pool (502 of the original 669 single-caller candidates), but only 6
of those had actually been tried. Hand-testing 7 more, spanning self_bytes
52 to 258 and including `if`/`else` branches, a `rescue` modifier, and a
multi-statement body wrapped in parens at a bare call site, all won (55 to
134 bytes each) -- giving a real rule: **a single-caller method called
bare on implicit `self` within the same class is safe and reliably
net-positive to inline if its body has no loop/iterator keyword and no
`return`/`yield`**, regardless of `if`/`else` or `rescue`. Filtering the
full 502-candidate pool to exactly that shape leaves 166 methods (35,669
combined `self_bytes`) -- a large remaining pool by this rule alone.

Attempting to apply that rule *automatically* across the full 166 --
generating each deletion/substitution mechanically (matching def
parameters to call-site arguments, splicing the body in) -- was tried and
abandoned after four rounds of real, escalating bugs, each caught by
re-verifying rather than trusting the previous fix:

1. The original single-caller scan (used across this whole ADR) turned
   out to record the wrong line number for a call site -- copy-paste had
   substituted the *def's* line for the *call's* line everywhere. The
   call *text* was right; the stored line number was always just the
   def's own line. Every one of the 6 already-shipped methods was
   unaffected only because each was found and verified by hand (a real
   `grep`, read in context) rather than by trusting that field -- but the
   automated batch trusted it blindly and generated 165 substitutions
   against the wrong location.
2. Fixed by re-deriving the true line from the call text -- which then
   exposed a second bug: naive substring search for the method name
   matched a `:battle_row` *symbol literal* (inside a `respond_to?`
   check) instead of the real call, corrupting the line.
3. Fixed with a token-boundary regex (rejecting a match preceded by `:`
   or a word character) -- which then surfaced call sites spanning
   multiple physical lines (a trailing comma continuing the argument list
   onto the next line) that a single-line substitution silently mangled,
   and bodies containing a `rescue`/`ensure` clause that can't be
   flattened into a semicolon-joined statement list without becoming a
   syntax error.
4. Excluding both, plus comment-only body lines and bare (paren-less)
   calls whose argument list has no unambiguous end, got every remaining
   candidate to pass a full-file `ruby -c`/`mrbc -c` check -- at which
   point continuing would have meant trusting a five-times-patched
   heuristic pipeline against 100+ methods with no per-method human
   review, in a real production codebase. That is a materially different
   risk than the six-line, individually-authored table this file already
   is. Stopped there rather than ship it.

Kept only the second batch of 7, each individually authored and verified
exactly like the original 11 (real before/after compile, diffed against
the actual generated output): `apply_tile_substitution`, `trunc_mod`,
`do_open_main_menu`, `max_hp_cap`, `continue_available?` (the `rescue`
case, spliced as a `rescue` modifier), `do_wait` (the `if`/`else` case),
and `draw_battle_row` (a 2-statement body spliced at a call site with a
trailing modifier `if`, sharing that source line with an untouched sibling
call to `rpg2003_party?`).

The other ~159 methods in the 166-candidate pool are real, by this rule,
and not yet done -- each still needs the same individual treatment (locate
the real call site by hand, splice, verify with a real compile) the 18
methods in this file got. That is the honest state to hand off, not a
partially-automated batch with unverified edge cases in it.

### What was verified

- The rewrite script's own output diffed directly against the exact
  hand-verified before/after text for all seven touched files -- identical.
- All seven rewritten copies pass `mrbc -c` (syntax) cleanly.
- `git status` on `mruby-rpg2k/mrblib/` after running the rewrite script:
  empty -- the real source is provably untouched.
- Every candidate's net effect (win or loss) was measured with a real
  `mrbc --remove-lv` compile before being included or rejected -- none of
  the duplication-cost numbers above are estimated.
- **Real whole-gem measurement**: compiled `mruby-rpg2k`'s exact wio-shaped
  `rbfiles` list with `mrbc --remove-lv` (matching this board's real
  flags), once with the seven original files, once with the seven
  rewritten copies swapped in: **477,860 -> 476,491 bytes (1,369-byte
  reduction)** for all eighteen methods combined (six single-caller, five
  from the 2-3-caller expansion, seven more single-caller from the
  validated-rule pass).
- Repo-wide grep (both `mrblib/**` and `scripts/**`) for every one of the
  eighteen method names, confirming no other real caller exists anywhere.

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

- A real, if modest, ~1,369-byte flash win for wio, at zero behavioural
  change everywhere else and zero loss of test coverage anywhere --
  `scripts/rpg2k_render_check.rb` and friends keep exercising the full,
  original definitions on every target.
- This is deliberately not a general inliner and not something to extend
  mechanically. Two pools were explored: the 2-3-caller pool (395
  methods, only 5 survived hand-testing -- most fail on a foreign
  receiver or a net-negative duplication cost, each only checkable by
  really compiling both versions) and the single-caller "no loop, no
  return" pool (166 methods after filtering, 18 of which -- the original 6
  plus these 7 -- are done). A real, validated rule exists for the
  second pool (see above), but *applying* it safely still costs one
  individually-authored table entry and one real compile per method --
  an attempt to automate that generation step hit four rounds of genuine
  bugs before being abandoned. ~159 real candidates remain in that pool
  for whoever picks this up next, each needing that same individual
  treatment, not a mechanical batch.
- desktop/psp/wasm/android builds are entirely unaffected -- they never run
  `wio_strip_inline_helpers` (gated on `build.name == 'wio'`) and keep
  compiling the real, unmodified source files directly.
