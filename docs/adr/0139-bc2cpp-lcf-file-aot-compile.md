# 139. A real, opt-in mruby-bytecode-to-C++ AOT compiler, proven on LCF::File

Date: 2026-09-10

## Status

Accepted

## Context

This session prototyped `bc2cpp.rb` (scratchpad-only, never in the repo): an
mruby-bytecode-to-C++ compiler that reads `mrbc`'s own two debug dumps (`-v`
disassembly and `-B -S` C dump) and translates a leaf method body into a
real C++ function, taking each mandatory argument as a plain typed
parameter instead of going through `mrb_get_args`/`mrb_funcall`. Two
optimizations came out of that work:

- **Devirtualization**: a whole-program (closed-world) scan finds every
  method name defined by exactly one class anywhere in the program. A call
  site using such a name is provably monomorphic -- it compiles to a direct
  C++ call, skipping `mrb_funcall`'s hash-based method lookup.
- **Ivar embedding**: an instance variable every `SETIV` site can prove is
  always the same primitive type (Fixnum) can be lifted out of the dynamic
  `iv_tbl` into a real struct field on an `RData` payload.

Both were verified on a toy example (byte-identical CRuby diff, inspected
at the objdump level) and then stress-tested against ~52,000 lines of real,
unmodified game source (`mruby-rpg2k`/`mruby-lcf`/`mruby-rgss`'s own
mrblib), which found and fixed six real bugs the toy example was too small
to expose (UTF-8 handling, `MODULE` nesting, mixed-type pool entries, a
non-`$`-anchored register regex silently under-counting embeddable ivars,
`LOADI8`/`LOADI16` literal loss, and a non-mandatory-argument arity
mismatch). That work produced real numbers (1,555 monomorphic method
names, 158 embeddable ivars, 147 of 1,947 real leaf methods compiling
clean) but never touched the actual repository -- everything lived in the
session's scratchpad.

The next ask was to actually start replacing interpreted bytecode with
generated C++ in the real, shipping build. Two decisions scoped the work
before it started: target **one small, self-contained real class** first
(with the interpreter as the unconditional fallback for anything not
compiled), and build it as a **new parallel, opt-in-only build path** that
never touches the default desktop/wio build.

## Decision

`LCF::File` and its four subclasses (`Database`/`MapTree`/`MapUnit`/
`SaveData`, `mruby-lcf/mrblib/lcf_file.rb`) are the target: small (121
lines total), self-contained, and this session already knew their
behavior in depth from the `method_missing` -> `Symbol` keys work earlier
in this branch's history.

Three pieces of new opcode support were needed and added to `bc2cpp.rb`
(now a real, in-tree tool at `tools/bc2cpp/bc2cpp.rb`, not a scratchpad
prototype):

- `RETFALSE`/`RETTRUE` -- a bare boolean return (`terminate_root?`'s own
  shape).
- `GETCONST`/`GETMCNST` -- top-level and module-qualified constant lookup
  (`LCF::Schema::DATABASE`'s own three-hop chain: `GETCONST LCF`, then two
  `GETMCNST`s), via `mrb_const_get`.
- Goto-threaded control flow -- every bytecode address any `JMP`/`JMPNOT`/
  `JMPIF` in a method can target gets a real C label (`L<addr>:`), and
  those opcodes translate straight to `goto`/conditional `goto`. This is a
  general, mechanical way to reproduce arbitrary branches (and, later,
  loops) without reconstructing a structured CFG. All registers are
  declared as plain locals before any label, so C++'s
  "goto must not skip an initialization" rule can never be violated here.

Two real, non-hypothetical bugs surfaced building this out, both fixed and
covered by the toy harness's own regression run (still byte-identical
against CRuby after every fix):

- The `goto` target used the disassembly's zero-padded address text
  (`"018"`) while the label was emitted from the integer address (`L18:`)
  -- a `goto L018;` with no matching label. Fixed by normalizing both to
  the same integer.
- `compile_send`'s method-name regex excluded `?`, so every predicate-style
  call (`rpg2003?`, `key?`, `is_a?`, `respond_to?`, ...) silently truncated
  to its non-`?` prefix in the generated `mrb_funcall` -- a real
  `NoMethodError` at runtime the generated C++ would have compiled and
  linked without complaint. Caught only by running against real code that
  actually calls predicate methods (the toy example had none).

A third, more structural finding came from wiring up the real build
integration: `bc2cpp.rb` now supports `ONLY_OWNERS` (restrict which
classes' methods actually get **emitted**, e.g. `"LCF::File,LCF::Database"`)
independently from the **registry**, which must still be built from the
whole closed world. Analyzed alone, `mruby-lcf`'s own mrblib makes
`LCF::Database#rpg2003?` look like the only `:rpg2003?` definition
anywhere -- but the real game also defines `Game::Actor`/`Party`/
`Battle#rpg2003?`, four definitions, genuinely polymorphic. `maker`'s own
`self.rpg2003?` call site happens to be safe to devirtualize either way
(the receiver is always a `Database`, by construction), but the registry
itself would have been unsound for any *other* future caller of
`.rpg2003?` in the whole program. `ONLY_OWNERS` narrows emission only;
`bc2cpp` is always invoked against the whole `mruby-rpg2k`+`mruby-lcf`+
`mruby-rgss` mrblib set.

A related gap: a devirtualized call can legitimately target a method
outside the emitted owner set (`LCF::File#to_lcf` devirtualizes into
`LCF.write_ber`/`LCF.binstr`, module functions on `LCF` itself, not one of
the five emitted classes) -- compiling clean but referencing two functions
this run would never define, an undefined-reference link failure waiting
to happen. `compile_send` now falls back to ordinary dynamic dispatch
whenever a monomorphic target's owner isn't in the emitted set -- always
safe (just slower), the same fallback an unmodeled opcode already gets.

`SKIP_UNSUPPORTED=1` drops any method whose body still contains a `#error`
marker from what's actually emitted, instead of emitting the `#error` into
a file the real C++ toolchain compiles (which would halt the build) --
each dropped method simply keeps running on the ordinary interpreted
path, mruby-lcf's own mrblib (already loaded by the time this gem's
init runs).

**16 real methods** compile clean and are registered: `header`/`schema`
on all four subclasses plus the shared `LCF::File` base, `terminate_root?`
(the base `false` and `MapUnit`'s own `true` override),
`rpg2003?`/`maker` on `Database`, and `LCF::File#key?`/`#to_lcf`.
Everything else on `LCF::File` (`#initialize`, `#[]`, `#[]=`,
`#method_missing`, `#respond_to_missing?`, `#save_to`) has an optional
argument, a block (`save_to`'s `File.open(path, 'wb') { |f| ... }`), or an
opcode this compiler doesn't model (`OCLASS`/`BLOCK`/`SENDB`) -- all stay
on the interpreter, `mruby-lcf`'s own mrblib.

### Build integration

A new gem, `mruby-lcf-compiled`, depends on `mruby-lcf` and only exists in
the gem list when `RPGMAKER_BC2CPP=1` (`build_config.rb`) -- disabled, its
only visible effect is that the directory exists on disk. Its
`mrbgem.rake` runs `tools/bc2cpp/bc2cpp.rb` at build time (via
`spec.build.mrbcfile`, the exact host `mrbc` the surrounding build already
produces -- the same mechanism mruby's own mrblib compilation already
uses, so this needs no new cross-compile plumbing) against the whole
closed-world source set, with `ONLY_OWNERS`/`SKIP_UNSUPPORTED` narrowing
what's emitted to the 16 safe methods above. `src/register.cxx` `#include`s
the generated file directly (its functions are all `static`, mirroring the
prototype's own toy harness) and its `mrb_mruby_lcf_compiled_gem_init`
calls `mrb_define_method` for each of the 16 -- safe to fetch
`LCF::Database` etc. via `mrb_class_get_under` here because mrbgems
dependency order guarantees `mruby-lcf`'s own gem init (C hook *and*
mrblib) has already fully run by the time a dependent gem's own init
starts.

## Consequences

**Verified real, not just compiled**: the actual `build_config.rb` +
`rake` pipeline (not a standalone script) built successfully end to end
with `RPGMAKER_BC2CPP=1` -- `register.cxx` compiled, linked into
`libmruby.a` alongside the other 39 gems. A separate, narrower host build
(`mruby-lcf` + `mruby-lcf-compiled` + their real dependencies only) let a
small harness construct each of the four file classes and call every
compiled method (`header`/`schema`/`terminate_root?`/`rpg2003?`/`maker`/
`key?`), diffing the output against the identical calls against a
build with `mruby-lcf-compiled` left out entirely (pure interpreter) --
**byte-identical** in both builds.

**Flash cost, not yet a saving -- now measured on the real target**: this
swap installs compiled overrides *alongside* the existing interpreted
bytecode (`mruby-lcf`'s own mrblib is untouched) -- the bytecode for all
16 methods is still compiled in and still reachable (via `#send`, or
simply because nothing was told to stop compiling it). A real `wio`
(Cortex-M4, `arm-none-eabi-gcc`) cross-build of `libmruby.a`, built twice
(`MRUBY_TARGET=wio`, with and without `RPGMAKER_BC2CPP=1`) and compared
with `arm-none-eabi-size`, confirms this precisely: `register.o`'s own
`.text` is 2,039 bytes, `mruby-lcf-compiled`'s own tiny gem-init wrapper
adds another 24, and the top-level `mrbgems/gem_init.c` dispatch table
grows by 8 bytes for the extra init/final function-pointer pair -- **2,071
bytes added** to the `wio_rgss_boot` image, against its 507,904-byte flash
budget. `mruby-lcf`'s own `gem_init.o` (the interpreted bytecode this
overrides) is byte-identical between the two builds (447,424 bytes both
times) -- confirming directly that nothing was removed. This session's own
scope was proving the pipeline correct and wired in, not a flash
reduction -- turning "compiled overrides installed" into "smaller flash
image" needs a follow-up that actually drops the now-redundant bytecode
for the classes this covers (nontrivial: `LCF::File` has other methods,
like `#initialize`, that still need the interpreter, so the whole file
can't simply be dropped from `spec.rbfiles`).

**Not done, explicitly out of scope for this pass**: a Renode boot check
with `RPGMAKER_BC2CPP=1` on a real `wio_rgss_boot` firmware image (this
ADR's own flash measurement only needed `libmruby.a`, not a full linked
firmware) -- this session's runtime *behavioral* verification (the diff
against the pure interpreter) stayed on the host/native build. Nothing in
the design is wio-specific (`spec.build.mrbcfile` already resolves
correctly under cross-compilation the same way core mruby's own mrblib
compilation does, confirmed by this same measurement's own successful wio
cross-build), but a real on-device (or Renode) boot exercising the
compiled `LCF::File` path specifically hasn't been run yet.

**What this proves for future targets**: the whole pipeline -- codegen,
narrowing emission via `ONLY_OWNERS` while keeping registry soundness,
falling back safely on any gap (unsupported opcode, non-mandatory arity, a
devirtualized target outside the emitted set), build-time generation via
the project's own `mrbcfile`, and runtime registration after the
dependency gem's mrblib has loaded -- now has one real, verified,
end-to-end example to extend from. The `RPGMAKER_BC2CPP=1` gate and
`ONLY_OWNERS` mechanism both generalize directly to a second target class
without new design work.
