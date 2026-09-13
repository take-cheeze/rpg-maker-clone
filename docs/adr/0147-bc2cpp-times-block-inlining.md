# 0147: bc2cpp `#times` block inlining (first real BLOCK/SENDB support)

## Status

Accepted.

## Context

A real Ruby block (`BLOCK`/`SENDB`) has been unconditionally unsupported since bc2cpp's first version -- the single largest remaining gap (a real closed-world survey found 727 `SENDB` + 53 `SSENDB` call sites, the most common real targets being `#each` (260), `#map`/`#each_with_index` (71 each), `#times` (41), `#any?` (39), `#select`/`#reject` (26/24), `#find` (21), `#reduce` (16)).

Two architectures were considered:

1. **Reuse the real interpreter for just the block** -- mruby exposes public APIs (`mrb_proc_new`, `mrb_funcall_with_block`) that look tempting: wrap the block's own already-compiled child irep in a real Proc and let the ordinary interpreter run it, general-purpose for any method/any block. Investigated and rejected: a plain `mrb_proc_new` builds an *unbound* Proc with no captured environment, and real blocks routinely close over an outer local variable -- confirmed directly against real source, not assumed (`@instants.each { |a, b| return b if pos >= a && pos < b }`, `mruby-rpg2k/mrblib/game.rb`, captures the enclosing method's own `pos`, and also has a non-local `return` inside the block). Building real closure/`REnv` capture on top of this shortcut would be at least as much work as inlining, plus a separate, intricate unwind mechanism for the non-local return (mruby's own break-tag machinery, invoked from inside an interpreter callback) -- rejected as not actually simpler.
2. **Inline the block body directly into the enclosing compiled function**, as native C++ control flow sharing the same registers. This gets outer-local capture and non-local `return` for free (see Decision), at the cost of only ever covering the specific methods this file explicitly recognizes -- a custom user-defined method that itself yields stays unsupported regardless (its own *callee* side would need separate BLOCK-receiving support, never addressed here).

Given (1)'s real correctness gap, (2) was chosen. Scoped to `#times` alone for this first round: `#times` has **zero** real bytecode-defined overrides anywhere in this program's whole closed-world registry (it doesn't even appear as a MONO/POLY entry at all) -- unlike e.g. `#each`, which real `Game::Actors`/`Game::Party`/`LCF::Array2D` all define their own competing versions of. Since no bytecode `#times` exists anywhere to override the real native `Integer#times`, calling `.times` on anything that isn't really an Integer is *already* a guaranteed real `NoMethodError` in the interpreted program today -- making a runtime `mrb_integer_p` guard that raises on mismatch provably equivalent to real dispatch for *every* possible receiver, not just "should never happen." `#each` and the rest stay out of scope until each one's own receiver-type story is worked out the same rigorous way.

## Decision

`recognize_times_regions` recognizes the one real shape (cross-checked against real disassembly, not assumed): `SENDB Ra :times n=0` immediately preceded by `BLOCK R(a+1) I[k]`, where child irep `I[k]` takes exactly one mandatory argument and nothing else.

`emit_times_inline` replaces both instructions with one native `for` loop:

- A runtime `mrb_integer_p` guard on the receiver, raising a real TypeError on mismatch (see Context for why this is sound for every receiver, not just the statically-expected one) -- the same trust model this file's own embedded-ivar `SETIV` codegen already uses (a real runtime guard even for a statically-proven type, never silent corruption).
- The block's own body, translated instruction-by-instruction (`compile_block_body_insn`) and inlined directly into the loop, using the enclosing method's own register numbering plus a fixed offset (`irep.nregs`) to keep the block's own locals disjoint -- re-initialized to nil at the top of *every* iteration (a fresh block activation each time, never leftover state).
- Two new opcodes, `GETUPVAR`/`SETUPVAR` (level 0 only), map an outer-local reference directly onto the enclosing function's own already-declared `r<N>` variable -- free, because inlining means "the outer scope" and "this same C++ function" are identical.
- The block's own non-local `return` (`RETURN_BLK`, confirmed via real disassembly and `vm.c`'s own `OP_RETURN_BLK` semantics) becomes a plain C++ `return` -- also free, for the same reason.
- The block's own *ordinary* return (`RETURN`/`RETNIL`/`RETFALSE`/`RETTRUE` -- confirmed directly that a real `next` compiles to a plain `RETNIL`, not `RETURN_BLK`) becomes a `goto` to the current iteration's own end label, since `#times` never uses the yielded value at all.
- `JMP`/`JMPNOT`/`JMPIF`/`JMPNIL` get their own dedicated handling (not delegated to the shared `compile_insn`) so their own `goto` targets use this block's own disambiguated label prefix, never the enclosing method's plain `L<addr>` convention -- C++ goto labels have whole-function scope, so a naive delegation risked a real, silent label collision (caught building this, not assumed: an early version delegated JMP-family opcodes to the shared codegen unmodified, and g++ rejected the resulting mismatched/undefined label immediately).
- Everything else delegates to the ordinary, unmodified `compile_insn`, with `idx: nil` -- which also cleanly disables `compile_send`'s own MONO `.new`-devirtualization inside a block body (a real missed optimization there, never a wrong one, since that optimization needs aligned backward-scan access to the true, un-offset instruction array).

If the block's own translated body isn't clean (any `#error` anywhere -- an unsupported opcode, including `BREAK`, which this round doesn't model at all, or a nested `BLOCK`/`SENDB`), the whole inlining attempt is discarded and both instructions fall through to the ordinary, honest `#error unhandled opcode BLOCK`/`SENDB` stubs -- confirmed directly with a real `break`-containing block.

## Verification

- Real runtime test against a freshly-built vanilla mruby core: a literal-integer receiver, a variable receiver, an outer-local accumulator (`total += i`), `next` (skips just the current iteration), a real non-local `return` from inside the block (exits the whole method, confirmed it does NOT run remaining iterations), and a non-Integer receiver (confirmed it raises rather than misbehaving). All pass.
- Real end-to-end regen of all three `*-compiled` gems: `mruby-lcf-compiled` byte-for-byte unaffected (no `#times` block sites); `mruby-rgss-compiled` gains 2 methods, `mruby-rpg2k-compiled` gains 14, zero regressions (full whole-program MONO/POLY registry diff is empty in both).
- All three gems' real `register.cxx` compile clean against real mruby headers with the regenerated output.
- Found and fixed two real bugs during this same verification pass, both caught by g++ rather than shipped: `E_TYPE_ERROR`'s own macro expansion hardcodes the identifier `mrb`, not this file's own `M` (same fix embedded-ivar `SETIV` codegen already needed); and the JMP-family label-prefix mismatch described above.

## Consequences

- `#each`/`#map`/every other Enumerable-family method stays unconditionally `#error` until its own receiver-type story is worked out -- `#each` specifically needs real per-call-site receiver-type proof (it has real bytecode-defined overrides in this program, unlike `#times`), not just the same mechanism pointed at a new method name.
- `BREAK` (a real `break` inside a block) is unmodeled -- correctly falls back to interpreted, never silently wrong.
- The inlining machinery itself (`compile_block_body_insn`'s register-offset/label-prefix scheme) is written generally enough that a future round targeting a different zero-override built-in shape shouldn't need to rebuild it from scratch -- only `recognize_times_regions`'s own shape-matching and the receiver-type reasoning are `#times`-specific.
