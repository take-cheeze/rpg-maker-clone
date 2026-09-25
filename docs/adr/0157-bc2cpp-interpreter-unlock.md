# 0157: bc2cpp interpreter unlock — return-type gate, Range#each, flat_map

## Status

Accepted.

## Context

25 skipped `Game::Interpreter` methods: 19 block-on-call-result
(`stat_targets(cmd).each`, `r.each`), 2 keyword, 3 JMPUW, 1
`&:sym`-on-unclean-callee. Every helper/callee already clean. Annotating
`cmd` buys nothing (the trace stops at the unrecognized SEND writer
regardless of argument class) -- what unlocks them is proving what the
*call results* are. `Annotations#ret` existed but was write-only (one
stderr read); `-> Array` normalized to nil.

## Decision

**A. Return-type Array gate.** `TYPES` gains `'Array' => :array`
(feeds the gate ONLY -- `native_c_type` deliberately has no `:array`
arm, so an argument-position Array token raises KeyError fail-loud).
New `annotated_array_return(name)`: MONO + `-> Array` on the def's own
irep label (POLY-safe by per-label keying, same argument as arg
annotations; no `compiles_clean?` -- the fact is only "returns fresh
Array"). Threaded into a shared `proven_array_source` helper
(backward scan to nearest destination-register writer; `select`/
`reject`/`map` unconditional + annotated returns) now consulted by
ALL FOUR recognizers (each/collect/accum/sym -- previously only sort
had the chained rule). Sound by per-method partitioning + the
emitters' own `mrb_array_p` tripwires (a wrong annotation raises at
first call, never miscompiles). One annotation placed:
`stat_targets (...) -> Array` (all four branches Arrays by
construction). +10 clean (9 stat_targets-fed + `Party#initialize` via
the replicated rule), zero regressions.

**B. Range#each inline.** `trace_new_target`: `RANGE_INC`/`RANGE_EXC`
→ `'Range'` (same end-of-trace gating as ARRAY; confirmed against
vm.c). `Game::Interpreter#range` (all paths `a..b`/`1..0`) via
single-entry `RANGE_RETURN_METHODS` allowlist in SUPER_TARGETS
tradition, caller-owner-verified. The recognizer now admits both one-argument
and zero-argument blocks; both forms receive the same frozen Range counter
semantics. Emitter clones each-loop with:
fixnum counter (no fetch), snapshot bounds (Ranges frozen),
overflow-safe `excl ? i < e : i <= e` (mrblib's `lim+=1` overflows at
MAX), two-part guard (`mrb_range_p` + Integer edges -- endless,
Float, succ-path raise, never unbounded), REAL excl flag (never
`begin==end`; the `1...1` source shortcut is unsound in general).
Fall-through leaves dest (each returns self). The real Wio hot-only LCF
output drops one cfunc/RProc fallback and 237 generated source bytes. 12-case
harness plus a zero/one-arity regression pass.

A second follow-up lets the same `times` inliner compile a literal block whose
only block use is the enclosing method's `yield`. This covers
`LCF::Array2D#each`; the method already extracts its received block as
`bc2cpp_blk`, so the inlined body calls `mrb_yield_argv` directly. The gate
requires one-level forwarding, a mandatory-arity enclosing method, no nested
block bodies, and the existing synchronous-method allowlist. The real Wio
hot-only LCF output drops from 5 to 4 cfunc/RProc fallbacks and 790 generated
source bytes. A runtime regression covers normal yields, block `break`, method
`return`, exceptions, missing-block recovery, and post-exception reuse.

**C. flat_map + full_heal rewrite.** `flat_map` joins COLLECT set
(1-arg); emitter mirrors mruby's own enum-ext shape exactly
(respond_to?-gate; Array expansion inline with `mrb_array_p`
tripwire -- Hash/Range yielders raise, a known deliberate narrowing:
only shape this file inlines, same class as Range's Integer guard).
Final-accumulator assignment fixed to include flat_map (harness-
caught: destination kept the receiver). Stopgap rewrite of
`permanent_states`/`full_heal` to index loops (identical order/side
effects, ADR-marked) so `full_heal` compiles before callee wiring.
`full_heal` + `permanent_states` CLEAN; `clear_states`
(`@states` unlayouted -- reassigned from `select`/`prune` sites) and
`cursed_armor_state_ids` (`it.state_set` opaque chain) stay -- both
receiver-side, documented.

## Verification

- Runtime harnesses (same link recipe): gate (annotated feeds inline;
  wrong annotation trips guard -- verified in codegen), Range (12:
  incl/excl/empty/descending/single/break/nonlocal/capture/vars/
  float-raises), flat_map (identity, scalar+array mix; nested blocks
  honestly stay interpreted). All pass.
- End-to-end regen: rpg2k 1718 -> 1738 clean (+20: 10 stat_targets-fed
  incl. `do_change_hp/mp/exp/level/skills/params`,
  `do_control_vars_range_variable`, `do_full_heal`,
  `do_simulated_attack`; `full_heal`/`permanent_states`;
  `Party#initialize`; 5 scene methods via replicated rule; Range
  sites pending receiver+body work), lcf/rgss unchanged, zero
  newly-skipped anywhere; non-block categories byte-identical.
- `g++ -fsyntax-only` clean; pre-commit clean.
- Capability only (bc2cpp.rb + 1 annotation + rewrite); no
  owners/register.cxx -- wiring separate. The 2 keyword + 3 JMPUW
  interpreter methods stay (unrelated gaps).

## Consequences

- `-> Array` annotations are now load-bearing: a wrong one raises at
  runtime (tripwire), but reviewers must still verify each placement
  (hand-placed, never inferred). Typo degrades to `#error`, never a
  wrong gate.
- Remaining interpreter work: `do_control_switches`/`do_control_vars`
  need Range sites + Range-typed `r` (range() allowlist covers the
  call; bodies must also be clean); `key_input_result` needs
  constant-Array reasoning (GETCONST literal); `do_jump_label` needs
  `@list` ClassLayout; `resume_inn` needs `full_heal` callee clean
  (done this round -- recheck post-wiring); `restore_call_stack`
  needs Hash-shape work (out of scope).
- flat_map's non-Array-yielder narrowing and Range's Integer-only
  narrowing are documented divergences that raise loudly; both match
  the file's established tripwire discipline.
