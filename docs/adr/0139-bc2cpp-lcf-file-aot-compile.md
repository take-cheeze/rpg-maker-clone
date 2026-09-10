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

## Follow-up: Game::Picture (mruby-rpg2k)

Extending to a second real class, in `mruby-rpg2k` this time (not
`mruby-lcf`), confirmed the pipeline generalizes -- and surfaced three more
real bugs, none of them hypothetical, all caught by the same discipline
(run it for real, diff it for real) this ADR's own LCF::File work
established.

`Game::Picture` (`mruby-rpg2k/mrblib/game.rb`) was picked by re-running
`bc2cpp` against the whole closed world and ranking classes by clean-method
ratio: 19/26 methods compiled clean even before any new opcode work, the
best real ratio of any class over ~40 methods. Getting the rest required
seven more opcodes, all mechanical mirrors of ones `bc2cpp` already had:

- `SUB`/`DIV` (`ADD`'s own fixnum-fastpath-else-`mrb_funcall` shape;
  `DIV` skips the fastpath entirely -- real Ruby integer division floors
  toward negative infinity, not C's truncating `/`, and duplicating
  `mrb_div_int`'s own rounding wasn't worth it for this prototype's scope,
  so it always goes through the real method).
- `SUBI` (`ADDI`'s own shape).
- `EQ`/`LT`/`LE`/`GT`/`GE` (`OP_CMP`'s own real shape, `src/vm.c`: a
  fixnum-fixnum fast path, else the real method by name).
- `LOADFALSE`/`LOADTRUE` (`LOADNIL`'s own shape) and `RETNIL` (a bare
  `return mrb_nil_value();`, the peephole mrbc itself emits for a
  tail-position bare `nil`).
- `LOADSYM` (`mrb_symbol_value(mrb_intern_cstr(M, "..."))`).
- `HASH` -- `HASH Rd N` builds a Hash from N key/value pairs held in `2N`
  consecutive registers starting at `Rd` (`(Rd,Rd+1)=(k0,v0)`, ...), the
  result overwriting `Rd` itself; every pair register still holds its
  original value when the `mrb_hash_new_capa`/`mrb_hash_set` sequence
  reads them (nothing writes `Rd` until the very end), so this is a
  straightforward unrolled loop. Needed `#include <mruby/hash.h>` in the
  generated file's own header block, the one real build-level omission
  (`mrb_hash_new_capa`/`mrb_hash_set` aren't declared by any header
  already included).

This got 25 of 26 real methods clean (only `#initialize`, which takes an
optional `opts = {}` argument, stays interpreted).

**A real memory-safety bug in the ivar-embedding pass itself**, never
exposed by `LCF::File` (which has zero embeddable ivars): `Game::Picture`
has 11 real, provably-Fixnum embeddable ivars (`@x`, `@y`, `@zoom`, ...),
but its `#initialize` is exactly the one method that can't compile
(optional args) -- so the `mrb_data_init` call that would allocate the
embedded struct never runs, and every *other* compiled method's own
GETIV/SETIV would read/write `DATA_PTR(self)` on an object that's still a
plain `MRB_TT_OBJECT`. Garbage or a crash, not a missed optimization, and
not something any `#error` check could ever catch (the generated code
compiles and links fine). Fixed with a new `CodeGen#drop_unsafe_embeddings`
guard, run once at construction: an owner's ivars are only treated as
embeddable if that owner has its *own* `#initialize` and it fits the pure-
mandatory-arity constraint everywhere else in this compiler already
requires. Verified with a matching toy case (`Calc`, 0-arg `#initialize`,
safely embeds; `Calc2`, optional-arg `#initialize`, correctly falls back to
the ordinary dynamic `iv_tbl` for a provably-Fixnum ivar the raw analysis
still reports as embeddable) -- both diffed byte-identical against CRuby.

**A real method-visibility bug, caught only by the runtime diff, not by
anything `bc2cpp` itself printed**: `Game::Picture#step` and `#finish_move`
are both `private` in the real interpreted source (a bare `private` call
before their own `def`s, in effect through the end of the class body) --
but the first hand-written `register.cxx` registered both with plain
`mrb_define_method`, silently making them public. `bc2cpp` itself doesn't
care (a private method is only ever legitimately reached via a self-
implicit call, which compiles identically either way), so nothing in
compilation ever flagged this -- it only surfaced as an observable
behavior difference: `picture.step(...)` raised `NoMethodError` against
the pure interpreter but silently succeeded against the first compiled
build. Fixed two ways: `build_registry` now tracks real Ruby visibility
(the bare `private`/`protected`/`public` mode-switch form, and the
`private :sym1, :sym2` retroactive form, both plain self-implicit sends to
`Kernel#private` etc. -- `SSEND0`/`SSEND` to that name), so `MethodDef`
carries a real `visibility`, and the `== compiled entry points ==`
diagnostic now flags a private/protected entry with the exact fix needed
(`mrb_define_private_method`, not `mrb_define_method`); and
`mruby-rpg2k-compiled/src/register.cxx` itself now uses
`mrb_define_private_method` for both. Re-verified byte-identical against
the interpreter afterward, this time including the now-identical
`NoMethodError` both builds raise on an illegitimate external `.step(...)`
call. Re-checked `LCF::File`'s own 16 registered methods against the same
new diagnostic -- all public, no latent bug there.

**Verified the same way**: the real `build_config.rb` + `rake` pipeline
built successfully with both `mruby-lcf-compiled` and `mruby-rpg2k-compiled`
enabled; a narrower host build (`mruby-lcf`+`mruby-rgss`+`mruby-rpg2k`+both
`-compiled` gems) let a harness construct a real `Game::Picture`, call
`move_to`/`update` (which drive real internal `step`/`finish_move` calls),
`to_h`, `erase!`, `shown?`, diffing full output against a build with
`mruby-rpg2k-compiled` left out -- byte-identical, including the
`NoMethodError` from the private-method fix above. LVGL is a real link-time
dependency of `mruby-rgss` even for a plain host/native build (undefined
`lv_*` symbols otherwise) -- satisfied with a small native stub library
(real signatures from `3rd/lvgl`'s own headers, no-op bodies), since this
harness never touches rendering.

**Flash cost, again measured on the real target**: a real `wio` cross-build
of `libmruby.a` with both `-compiled` gems enabled, compared against the
LCF-only baseline via `arm-none-eabi-size`: `mruby-rpg2k-compiled`'s own
`register.o` is 5,120 bytes of `.text`, its gem-init wrapper another 24,
the shared dispatch table's growth 8 more -- **5,152 bytes added** for
`Game::Picture` alone, **7,223 bytes total** for both compiled gems
together, against the 507,904-byte budget. `mruby-rpg2k`'s own
`gem_init.o` (its interpreted bytecode) is byte-identical `.text`/`.data`/
`.bss` between the two builds (a raw `ls -la` byte count differed by 12
bytes, entirely explained by the two builds' own directory path strings
embedded in debug info, not by any code difference) -- confirming again
that nothing was removed, only added.

## Follow-up: whole-program call-site argument-type inference

A cheap, deliberately narrow extension: for a method name with exactly
one real definition (MONO -- the same registry devirtualization and
`IvarLayout` both already trust), *every* `SEND`/`SSEND` anywhere in the
program sending that name can only be calling this one definition
(dispatch is by name, not signature, so pooling a POLY name's call sites
this way would be unsound -- each one could be targeting a different real
method). `ArgTypes.analyze` walks every such call site's own argument
registers with `IvarLayout.trace_type` itself (the exact same backward
scan `SETIV` sites already use, just re-pointed at a `SEND`'s argument
registers), and feeds the result back into `IvarLayout.trace_type`'s own
"opaque incoming argument" fallback -- a `SETIV` whose only source is a
bare method parameter (previously always `UNKNOWN`, e.g. the toy
example's own `Animal#@name`) can now embed when every real caller
happens to pass the same primitive type there.

Run against the whole `mruby-rpg2k`+`mruby-lcf`+`mruby-rgss` closed world:
71 real argument positions across the whole program inferred `fixnum`,
but **zero new ivars unlocked** in that same real code. The reason is
structural, not a bug: `X.new(args)` compiles to `SEND :new` -- `Class#new`
is a C-defined core method, invisible to this bytecode-only registry --
never a real `SEND :initialize`, confirmed against the actual
disassembly. So `#initialize`'s own arguments are permanently invisible to
this mechanism, and `#initialize` is exactly where nearly every real
ivar-from-argument pattern in this codebase lives (`Game::Picture`'s own
`@x = opts[:x] || 0`-shaped `#initialize` included -- a Hash-default
pattern this compiler doesn't parse yet regardless).

Verified the mechanism itself is sound on the one real shape it *can*
reach: a bare argument assigned to an ivar in a method other than
`#initialize` (a real setter, `#foo=`, reached by an ordinary `obj.foo =
value` `SEND`, not by `.new`). A new toy case (`Sized#n=`, called once
with a literal `42` from `SizedUser#make`) confirmed `@n` becomes
embeddable only because of this pass, generates the same guarded
`DATA_PTR(self)` struct write every other embedded ivar gets, and diffs
byte-identical against CRuby end to end. Re-verified both already-shipped
targets (`LCF::File`, `Game::Picture`) emit byte-identical output with this
change applied -- this pass only ever *adds* embedding opportunities that
weren't there before, never changes an existing one, so a real-code
no-op result is exactly what a correct implementation should produce
given this codebase's own actual `#initialize`-heavy style.

Not pursued further in this pass: usage-based type inference (typing a
register from the *set* of methods called on it, intersected against the
whole-program class registry) would reach further, but needs real
dataflow across the now-arbitrary goto-threaded control flow rather than
this pass's straight-line backward scan -- a materially bigger piece of
work, left as a real, understood next step rather than attempted here.
