# 0287. bc2cpp: a per-loop Fixnum guard for inlined step/upto/downto loops

Date: 2026-09-30

## Status

Accepted

## Context

ADR 0273 inlines `recv.step(limit, lit) { }`, `recv.upto(limit) { }` and `recv.downto(limit) { }`
as a `long long` counter loop when both bounds are proven Fixnums, so every counter value between
them needs no boxing. ADR 0279 retired "an ADD/SUB/MUL result is a proven Fixnum" (a result can be
a bignum, and under word boxing one past `MRB_FIXNUM_MAX` is a heap Integer), so a bound such as
`n + 2` or `(n * 2)` is an Integer the proof no longer calls a Fixnum and the loop went back to a
block call (`scripts/bc2cpp_step_inline_check.rb` pinned `upto_dynamic` / `downto_dynamic` as kept;
the pin was vacuous for `upto`: `upto` was not in `BLOCK_FALLBACK_UPVAR_SAFE_METHODS`, so that site
was a `#error` and, under `SKIP_UNSUPPORTED`, the whole method was dropped).

Two ways back were on the table:

- (a) prove the bound's interval fits the Fixnum range on every target. The unmerged
  prototype of ADR 0286 (`tools/bc2cpp/int_range.rb`, `array_cells.rb`, about 4,500 lines) is an
  interval domain for this.
- (b) test the bound once before the loop and keep the existing call as the fallback.

## Decision

**(b).** `emit_step_inline` admits an operand that is not a literal or a proven Fixnum when the
numeric class-set proof (ADR 0276) says it is exactly Integer (`NumericFlow::INT`; a Float or a
possibly-Float operand is refused as before). Every such operand is collected into one test, and the
method gets

    if (mrb_fixnum_p(rA) && mrb_fixnum_p(rB)) { <the inlined loop> }
    else { <the ordinary BLOCK_FALLBACK call of the same site> }

Both registers are read once, before the loop, so the test is per loop, not per iteration. Inside
the `if` the ADR 0273 argument holds unchanged: both bounds are Fixnums, so the `long long` counter
(which cannot wrap a 32-bit `mrb_int`, the step is a literal of at most `0x3fff_ffff`) only ever
holds Fixnum values and `mrb_fixnum_value((mrb_int)i)` is exact on the 64-bit build, the 32-bit
`mrb_int` targets and 31-bit word boxing. A bignum bound goes to Integer's own `upto`/`step`/
`downto` through `mrb_funcall_with_block` with the block compiled as a standalone cfunc, which is
the code the site had before this ADR. The guard is the same tag test the ADR 0279 Fixnum tier
already uses, so no new runtime dependency and no fixnum-range constant is written into the
generated code.

- The fallback block function is the ordinary BLOCK_FALLBACK one (`step_loop_guard_fallback`). A
  block that is not fallback-safe, or whose function cannot be emitted, leaves the site
  un-inlined, exactly as today; the body's own nested cfuncs are dropped with it.
- A resumable (flat) loop is never guarded. Its body may `Fiber.yield`, which the fallback call
  cannot resume, so a flat loop still needs both bounds proven Fixnums (ADR 0273).
- `upto` joins `downto` and `step` in `BLOCK_FALLBACK_UPVAR_SAFE_METHODS` (Integer and String
  `upto` yield synchronously and keep no block; the program defines no `upto`), so an `upto` site
  the inliner does not take compiles as an ordinary block function instead of `#error`.

**(a) is not ported.** The measurement below shows the recovered population is one loop. The
interval domain could prove it too (`digits_of`'s `n` is one of two constants, chosen in
`editor_digits`), but
a guard recovers it without a whole-program range analysis whose own soundness arguments (widening,
array-length facts, 31-bit vs 62-bit bounds per target) would have to be carried and reviewed. If a
later loop needs an interval fact for another reason (an in-range array index, the ADR 0286 goal),
that work should be argued on that benefit, not on this one.

## Consequences

- Measured on the tree at the time of writing (`bc2cpp.rb`, SKIP_UNSUPPORTED=1):
  - the wio closed world of the three compiled gems: 1 inlined step loop before (`LCF` `7.downto(0)`),
    2 after; the new one is `Scene::DebugMenu#digits_of`'s `(n - 1).downto(0)`, which had been the
    only `BLOCK_FALLBACK :downto` of the game. The remaining `upto`/`downto` sites in
    `mruby-rpgxp` and `mruby-wolf` are not in the compiled gems;
  - optcarrot (`3rd/optcarrot/lib`, its own closed world): no change. Its `step` loops are
    literal-bounded (already inlined, four of them resumable/flat in `PPU#main_loop`); the other
    sites are a computed step (`first.step(last, second - first)`) or sit in the driver.
- Cost: one integer tag test per inlined loop entry on the guarded sites, and the block body is
  compiled twice (inlined, and as the fallback cfunc), so a guarded site roughly doubles that
  block's generated code. The fixture has 27 guarded sites; the game has one.
- `scripts/bc2cpp_step_inline_check.rb` now pins the guard (`STEP_LOOP_GUARD`, `BLOCK_FALLBACK`,
  the test in front of the loop and not in it), keeps Float-tainted bounds, unknown operands and a
  flat loop un-guarded, and compares compiled with interpreted results for bounds at, just inside
  and just past `MRB_FIXNUM_MAX` / `MRB_FIXNUM_MIN` (inlined and fallback branch, positive and
  negative step, `break` / `next` / `return` / `raise` through the fallback, captured locals, an
  ivar, a nested block, an empty range) on a 64-bit and, through `BC2CPP_MRUBY_FULL32` /
  `BC2CPP_MRBC32` (`-DMRB_32BIT -DMRB_INT32`), a 32-bit-`mrb_int` build. Dropping the guard from the
  generated code makes both halves fail.
- The 32-bit build simulated on a 64-bit host stores a block function's address in a 32-bit
  `mrb_int`, so the run links with `-no-pie` to keep code addresses below 2 GB. A real 32-bit target
  has 32-bit pointers and is unaffected. CI does not run a 32-bit-`mrb_int` build (as for ADR 0279),
  so that half is a local check.
- Residual risk: the fallback relies on the ADR 0273 assumption that `Integer#upto`/`downto`/`step`
  are not redefined in the program (unchanged; the guard does not test the method) and on
  NUMERIC_OPERAND_PROOF being right that the operand is an Integer (a wrongly proven operand that is
  in fact a Float fails the tag test and takes the call, which is the interpreter's behaviour, so
  the guard also narrows that proof's risk here). A literal step, and therefore the counter width,
  is unchanged from ADR 0273.
