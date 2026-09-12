# 0145: bc2cpp RESCUE/RAISEIF/EXCEPT support (real `begin...rescue...end` compilation)

## Status

Accepted.

## Context

Every real `begin...rescue...end` (or, identically, a whole method body with
a trailing `rescue` clause -- real Ruby desugars both to the same bytecode
shape) has been a permanent, documented bc2cpp gap since day one
(docs/adr/0139): `compile_insn` has no case for the `EXCEPT`/`RESCUE`/
`RAISEIF` opcodes mruby's own compiler emits for one, so any method using
one falls through to the generic `#error unhandled opcode ...` fallback and
stays interpreted, permanently paying both the interpreter's own overhead
*and* (once RPGMAKER_BC2CPP=1's own wio bytecode-stripping, docs/adr/0144,
applies) never becoming eligible for that stripping either.

A real, closed-world survey (`bc2cpp.rb`/`compiled_gems.rb`'s own whole
mrblib source set, `SKIP_UNSUPPORTED=0` so every real `#error` marker stays
visible) found:

- 102 real methods across the whole program blocked *only* by this gap (no
  other unsupported opcode in the same body) -- 93 of them inside the
  101 owners `mruby-lcf-compiled`/`mruby-rgss-compiled`/
  `mruby-rpg2k-compiled` already cover today.
- 366 blocked only by `BLOCK`/`SENDB`/`SSENDB` (a real Ruby block/yield --
  a separate, much larger feature, out of scope here).
- 23 blocked by both.
- Every real rescue clause in `mruby-rpg2k/mrblib` (147 of them) already
  fits one exact, narrow shape: a single rescue class (`StandardError`
  overwhelmingly, a handful of `NameError`/`RuntimeError`/
  `RGSS::Timeout`), no `retry` (0 real uses), essentially no `ensure` (1
  real use, itself excluded, never mistranslated). Real Ruby's exception
  model allows far more than this (multi-class rescue, retry, ensure,
  nested rescues) -- none of it is needed for what this program actually
  contains, so this round only ever targets the one shape that's real.

## Decision

Recognize and compile exactly that one shape; anything else keeps falling
through to the existing, honest `#error` path unchanged.

**Shape** (`recognize_rescue_regions`, cross-checked against the real
disassembly of `Game::Actors#[]`, not assumed from `vm.c` alone): a real
catch handler entry (`clen`/`mrb_irep_catch_handler` -- mrbc's `-v` dump
prints it as a `catch type: rescue   begin: B end: E target: T` header
line, now parsed into a new `CatchHandler`/`Irep#catch_handlers`) whose
`[B, E)` is the protected computation, `E` is exactly one `JMP S` (the
success exit, landing on the exact same final `RETURN`/`RETURN_BLK` every
rescue-match path also converges on -- true because a real rescue clause is
always the last construct in its own method/`begin` block), and `T` is
exactly `EXCEPT`/`GETCONST`/`RESCUE`/`JMPIF`/`JMP`/.../`RAISEIF` matching
real Ruby's own single-class-match-or-reraise semantics. Full containment
is checked by real jump *source* address (not just which addresses appear
as some target somewhere -- an earlier, blunter version of this check
passed a hypothetical external jump landing exactly on `B` itself, e.g. a
`retry`'s own back-edge; fixed before this ever shipped, moot in practice
since retry is confirmed absent from every real rescue clause here, but
checked properly regardless of what's *currently* true).

**Codegen**: `mrb_protect_error` (3rd/mruby/src/error.h) -- the same real,
core primitive `GETCONST`'s own owner-scope lookup already uses
(`bc2cpp_const_try`) -- runs the protected computation, extracted into its
own standalone top-level function (`mrb_protect_error`'s body parameter is
a plain C function pointer, so it can't be a closure; live-in state at
`begin_addr` is always just `self` + this method's own mandatory
arguments, since `begin_addr` is always the very first real instruction
after `ENTER`, so a small by-value `Ctx` struct carries exactly that).
Either it returns the try body's own real result with `err==FALSE` --
which *is* the whole method's own final return value here, since success
and every rescue-match path share one final `RETURN` -- or it returns the
raised exception object with `err==TRUE`, exception state already cleared
and the call-info stack already unwound (`mrb_protect_error`'s own real
`MRB_CATCH` branch, read directly). `RESCUE`/`RAISEIF` themselves get
real, unconditional (not shape-gated) `compile_insn` cases -- direct,
mechanical transcriptions of `OP_RESCUE`/`OP_RAISEIF`'s own real `vm.c`
bodies, safe wherever they appear since nothing else in this file can ever
put anything but a real exception-or-nil into the registers they read.
`EXCEPT` itself stays `#error`-only outside a recognized region -- it has
no meaningful translation without this recognizer's own glue providing a
real value for it, unlike the other two.

## Verification

- Real runtime test (not just "compiles"): a small `mrb_protect_error`/
  `mrb_exc_raise`-based harness against a real, freshly-built vanilla
  mruby core, exercising the actual compiled `Actors#[]` byte-for-byte as
  bc2cpp generates it -- success path (real object returned and cached),
  rescue-match path (caught, `$stderr` logged exactly once, second lookup
  doesn't re-log), non-matching exception class (an `ArgumentError`
  correctly re-raises *past* this `rescue RuntimeError` clause, exactly
  like real interpreted Ruby), and the pre-`begin` guard clause (an early
  `return nil if ...` before the protected region ever runs). All four
  pass.
- Real end-to-end regen of all three `*-compiled` gems (real `bc2cpp.rb`
  run, real owner lists from `compiled_gems.rb`): `mruby-lcf-compiled`
  byte-for-byte unaffected (12 owners, none blocked by this gap); `mruby-
  rgss-compiled` gains 2 real methods (`RGSS.singleton#_comparison_sign`,
  `RGSS::Graphics.singleton#render_fps`); `mruby-rpg2k-compiled` gains 91.
  The only *other* changes anywhere in either diff are call sites that
  devirtualize from `mrb_funcall` to a direct C++ call because one of
  these newly-unlocked methods is what they were calling all along (e.g.
  `RPG2k::Scene::Base#play_system_se` itself was one of the 91, so its own
  ~152 real call sites across the program devirtualize too) -- the same
  established cascading effect every prior coverage round already
  produces, not a new risk.
- All three gems' real `register.cxx` compile clean against real mruby
  headers with the regenerated output.

## Consequences

- `BLOCK`/`SENDB`/`SSENDB` (Ruby blocks/yield) remains the single largest
  real remaining gap (366 methods) -- a materially different, larger
  feature (closure/upvalue capture, not a catch-table extraction), tracked
  separately.
- The one real `ensure` clause in `mruby-rpg2k/mrblib`, and any future
  rescue clause using `retry`, multiple rescue classes, or nesting, stay
  interpreted -- correctly, not silently -- until a future round
  specifically extends `recognize_rescue_regions`' own shape check for
  that exact new case, re-verified the same way this one was.
