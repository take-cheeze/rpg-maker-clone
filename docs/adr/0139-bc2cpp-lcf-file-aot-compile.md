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

## Follow-up: RGSS native method name registry extraction

bc2cpp's whole-program registry (`build_registry`) only ever sees methods
`def`'d in Ruby -- it walks `mrbc`'s own bytecode dump, so a method
registered directly onto a class via C++ (`mrb_define_method` and its
`_class_method`/`_module_function` siblings, the shape every RGSS class
--`Sprite`, `Bitmap`, `Viewport`, `Window`, `Rect`, ... -- uses in
`mruby-rgss/src/lib.cxx`) is invisible to it. Since the registry keys
purely by bare method *name* (dispatch is by name, not by class -- see
`build_registry`'s own comment), a name real bytecode defines exactly
once still looks MONO even when a *different* class registers a
same-named method natively -- unsound wherever that collision happens.

Checked first, before writing anything, whether a *direct* devirtualized
call into one of these native C++ methods (skipping `mrb_funcall`'s own
method-table lookup, mirroring what this pass already does for MONO
bytecode names) could also be made sound and worth adding here. It
can't, not without a lot more work than this pass attempts: every
`mrb_get_args`/`mrb_get_argc` call reads the current call's arguments
from `mrb->c->ci` (the VM's own call-info frame), and that frame is only
populated by `mrb_funcall`'s own `cipush` + `funcall_args_capture` +
`ci->u.target_class`/`ci->mid` assignment (confirmed reading
`3rd/mruby/src/vm.c`'s `mrb_funcall_with_block`, lines 797-865, and
`3rd/mruby/src/class.c`'s `get_args_v`) -- a raw C function is only ever
invoked as `(mrb_state*, mrb_value self)`, with every actual argument
already staged into that frame beforehand, never passed as direct C
parameters. Calling an RGSS method's function pointer directly would
skip all of that setup, so any `mrb_get_args` inside it would read a
stale or wrong frame -- a real correctness bug, not a missed
optimization. So this stays a **registry-soundness fix only**: extract
just the flat set of names these call sites register, never an owner
class or a callable C++ symbol (neither is needed to make MONO/POLY
accounting sound again), and never attempt a direct call into one.

`extract_native_method_names` scans a list of C/C++ source files for
`mrb_define_method`/`mrb_define_class_method`/`mrb_define_module_function`
call sites and pulls out each one's literal method-name argument (a
single multiline-aware regex -- these calls are mechanically regular, no
real C++ parsing needed). The CLI driver merges the result into the
registry as synthetic `MethodDef`s with `owner: '<native>'` and
`irep: nil` before any analysis runs, gated behind a new `NATIVE_SRCS`
env var (shell-word-separated source paths) that's optional the same way
every other env knob here is -- omitting it just leaves the registry as
unsound as it always was with respect to that native gem.

A `MethodDef` with `irep: nil` has no bytecode body -- three real crash
sites had to be guarded once this was wired up and run for real
(`IvarLayout.analyze`'s `methods_of`/`def_of_irep` building,
`ArgTypes.analyze`'s per-name walk, and `monomorphic_target` itself, the
function every direct-call decision in `compile_send` goes through) --
each now simply skips/excludes a native-only entry rather than
dereferencing a `nil` irep label. `monomorphic_target` in particular
means a name that's *only* ever natively defined (no bytecode
definition anywhere) just falls back to ordinary dynamic dispatch, same
as any other call this compiler can't resolve.

Ran against `mruby-rgss/src/lib.cxx` (115 unique method names across its
199 real `mrb_define_method`-family call sites) merged into the real
`mruby-rpg2k`+`mruby-lcf`+`mruby-rgss` closed world: **6 real name
collisions found and fixed** -- `:x`, `:y`, `:width`, `:height`, `:ox`,
`:oy` all flipped from MONO to POLY. Every one is a genuine, previously
unsound case with exactly the same shape as this ADR's own earlier
`Game::Shop#name` bug: `RGSS::Sprite`'s own bytecode-level readers
(`mruby-rgss/mrblib/lib.rb`, e.g. `def x; @x || 0; end`) share a bare
name with `RGSS::Rect#x`/`RGSS::Rect#width`/`RGSS::Rect#height` and
`RGSS::Viewport#ox`/`RGSS::Viewport#oy`, both registered natively in
`lib.cxx` -- a different class entirely. Before this fix, any compiled
call site sending `.x` anywhere in the whole program would have been
devirtualized straight into `RGSS::Sprite`'s compiled body regardless of
the receiver's real class -- silently wrong (or a crash, depending on
the receiver's actual shape) had a compiled caller ever reached one of
these names with a non-`Sprite` receiver.

Re-verified both already-shipped targets (`LCF::File`-family,
`Game::Picture`) two ways: first by replaying `mruby-lcf-compiled`/
`mruby-rpg2k-compiled`'s own exact `bc2cpp.rb` invocation by hand with
`NATIVE_SRCS=mruby-rgss/src/lib.cxx` added, then for real -- running the
actual `rake <build_dir>/lcf_compiled_gen.cpp
<build_dir>/rpg2k_compiled_gen.cpp` targets through this repo's real host
build (`RPGMAKER_BC2CPP=1`) with `mrbgem.rake` now wiring
`NATIVE_SRCS = Dir["mruby-rgss/src/*.cxx"]` into both gems. Both ways,
both targets emit **byte-identical output** with this change applied --
neither one happens to call any of the 6 flipped names from a compiled
call site, so this is a real, verified safety fix with zero effect on
what's actually shipping today, not a live bug in either compiled gem.

Built and verified a minimal end-to-end toy case on top of the existing
`classes.rb`/`toy.rb`/`main.cxx` harness (not part of the git repo, a
scratch reproduction only): added `Calc2#label` on the bytecode side, a
plain-text native fixture file with a colliding `mrb_define_method(...,
"label", ...)` on a different (fictional) class, and a top-level
`read_label(o) = o.label` call site. Without `NATIVE_SRCS`, `:label`
looks MONO and `read_label` compiles to an unsound direct call
(`Calc2_label_impl(M, r3)`) regardless of what `o` actually is -- the
exact bug shape above, deliberately reproduced small. With the fixture
fed in via `NATIVE_SRCS`, `:label` correctly flips to POLY and the same
call site compiles to `mrb_funcall(M, r3, "label", 0)` instead. The full
harness (built with the fixed, safe codegen) still runs byte-identical
against `ruby toy.rb`, including the new `read_label(calc2)` call.

`mruby-lcf-compiled/mrbgem.rake` and `mruby-rpg2k-compiled/mrbgem.rake`
both now pass `NATIVE_SRCS = Dir["mruby-rgss/src/*.cxx"]` (currently only
`lib.cxx` actually defines any methods; the rest are globbed too so a
future native method added to another file in that directory is picked
up automatically) and add those files to the generated file's own
prerequisites, so a change to RGSS's native method set correctly
triggers regeneration.

## Follow-up: magic-comment argument-type annotation

`ArgTypes` (above) is structurally blind to `#initialize`'s own
arguments -- `X.new(args)` always compiles to `SEND :new`, never `SEND
:initialize` -- and `#initialize` is exactly where nearly every real
ivar-from-argument pattern in this codebase lives. Closing that gap needs
an actual type declaration from somewhere other than call sites. Chose a
plain Ruby comment over a real Ruby-syntax annotation (a `sig(...)`-style
method call before the `def`) specifically because every other bc2cpp
feature so far has *zero* effect on the interpreted path: a comment is
invisible to `mrbc` (stripped at parse time, long before any bytecode
exists), while a real method call would need a stub defined in mrblib and
would execute on every load of that class body, compiled or not -- a real
behavior and performance cost this project's whole opt-in design
deliberately avoids everywhere else.

Syntax: `# bc2cpp: (T1, T2, ...) -> T3` on the line immediately above
(blank lines skipped) a `def`. Only `fixnum`/`Fixnum`/`Integer` mean
anything today, matching the one primitive type `IvarLayout`/`ArgTypes`
themselves already model; any other token is simply not recognized (never
an error).

Finding the comment needed a small new data source: `mrbc -v`'s own
disassembly already prints a `file: path/to/x.rb` line at the top of each
irep block (previously discarded by `parse_disasm_blocks`) plus real,
1-indexed source line numbers on every instruction (confirmed: a leaf
method's own `ENTER` instruction's line number lands exactly on its `def`
line). `Annotations.extract` uses that -- no new source-text parser, no
correlating anything by name or textual order, just open the exact file at
the exact line `mrbc` already reports and look one line up.

Unlike `ArgTypes`, an annotation is safe for *any* method regardless of
how many other classes define the same name: it names its own irep
directly (found via `MethodDef#irep`, one per real `def`), never pooling
call sites under a name the way `ArgTypes` has to (which is exactly why
`ArgTypes` stays restricted to MONO names -- a POLY name's call sites
could each be targeting a different real method). This is what makes
`#initialize` -- about as POLY a name as they come, since nearly every
class defines one -- safe to annotate at all. Wired into
`IvarLayout.trace_type`'s own "opaque incoming argument" fallback,
checked before `ArgTypes`' pooled inference (both only ever add embedding
opportunities, never remove one).

A wrong annotation cannot silently corrupt anything: `IvarLayout`'s own
`SETIV`-embedding codegen already guards every embedded write with a real
`mrb_integer_p` check + `mrb_raise` regardless of how the type was
established (a literal, `ArgTypes` inference, or this) -- lying in a
comment just means a real `TypeError` at runtime instead of a wrong
build, the same safety net every other embedded ivar already has.

Verified with a new toy case (`Budget#initialize(capacity)`, annotated
`# bc2cpp: (fixnum) -> nil`): confirmed `@capacity` is UNKNOWN and stays
un-embedded with the comment removed, and correctly embeds
(`EMBED Budget#@capacity (fixnum)`) with it present; the full harness
(built with the annotated, embedding codegen) runs byte-identical against
`ruby toy.rb` end to end, `Budget.new(500).capacity` included. Re-verified
both already-shipped targets (`LCF::File`-family, `Game::Picture`) emit
byte-identical output through the real `rake` build path -- neither has
any magic comments yet, so `Annotations.extract` finds nothing for either,
exactly the no-op result a correct implementation should produce.

### Where hand annotation would actually help in the real codebase

Added a second, purely diagnostic pass, `report_annotation_candidates`:
for every real `def`, find every `SETIV` site whose source register,
tracing back through `MOVE` chains, was *never* written by anything else
in that method body (a true opaque incoming argument, in a mandatory-arg
position) and isn't already resolved by `ArgTypes` or an existing
annotation -- mirroring `drop_unsafe_embeddings`' own gate (a class whose
`#initialize` isn't purely mandatory-arity can never embed *any* ivar
regardless of what else is annotated, so those are excluded too, or the
count would overstate what annotation can actually unlock).

Run against the whole `mruby-rpg2k`+`mruby-lcf`+`mruby-rgss` closed
world: **37 real candidate argument positions** (roughly 26 methods),
**21 of them (14 methods) owned by `mruby-rpg2k` itself** -- the gem this
question was actually asked about. That's the honest structural number:
every position on this list is a case where nothing *but* annotation
could unlock the ivar (call-site inference literally cannot reach it).

It is not, however, the number of positions actually worth annotating --
`fixnum` is still the only type this compiler understands, and most of
these aren't Fixnum-typed at all. Spot-checked several real ones by
reading the actual source: `RPG2k::Scene::Map::LRUBitmapCache#initialize
(capacity_bytes)` is a genuine, correct target (`@bytes > @capacity_bytes`
a few lines later is a real numeric comparison); `RPG2k::Scene::
{Item,Skill}Menu#enter_target_confirm(lock)` is not (`lock == :self` and
a bare `enter_target_confirm(nil)` call site both appear in the same
class -- `lock` is `nil`/Symbol-typed, not Fixnum); `RPG2k::Scene::
Menu#enter_actor_selection(key)` looks the same way (`@focus = :actors`
sits right next to it). Most of the 21 are class/scene/state object
references (`@parent`, `@scene`, `@state`, `@map`, `@owner`, ...), never
annotatable under this compiler's current one-type model regardless. A
real accounting would need reading each candidate's actual usage the same
way, which this pass deliberately doesn't attempt -- it only finds
*where* to look, not what type is actually there.

### Automatic annotation

Partially possible, not fully. For a MONO name's *non*-`#initialize`
methods, `ArgTypes` already infers the type automatically from real call
sites -- there's nothing to hand-annotate there in the first place, the
whole point of that pass. For the real gap (`#initialize`, and any POLY
name `ArgTypes` can't pool), no static derivation is possible without
either a human actually reading the usage (as above), or a **dynamic**
source: this project already diffs real gameplay behavior byte-for-byte
between interpreted mruby and CRuby throughout its own test/verification
process (this ADR's own verification steps included) -- the exact same
mechanism could drive a lightweight runtime profiler, instrumenting every
`report_annotation_candidates` method (a `TracePoint` or a thin
`prepend`-based wrapper, loaded only for this one profiling run) to record
the real Ruby class of every argument actually passed across a real
CRuby test/logic-check run, then auto-emit a magic comment wherever every
observed call agreed. That would give broader, *executed* coverage than
`ArgTypes`' own static call-site scan (catching call sites `ArgTypes`
already can't reach for other reasons too, like `#send`), at the same
evidentiary weight `ArgTypes` itself already has -- strong evidence, not
a soundness proof, so still subject to the exact same guarded-write
safety net every annotation gets regardless of its source.

Built as `tools/bc2cpp/profile_annotations.rb`: runs `bc2cpp.rb` for
real (the same closed-world source list/`NATIVE_SRCS` both real
`mrbgem.rake`s use) to get the live candidate list, then re-runs this
project's own real CRuby game-logic harnesses
(`scripts/rpg2k_logic_check.rb`, `scripts/rpg2k_scene_check.rb`, and
others) each in its own clean subprocess with a `TracePoint(:call)`
probe installed, recording the real Ruby class of each candidate's
argument on every real call. Chose `TracePoint` over a
`Module#prepend` wrapper specifically because it needs no class to
already exist at install time -- it matches dynamically as real
classes get defined, so one unmodified probe works across every
harness regardless of load order. A first version had a real bug,
caught before it was treated as done: it emitted one "ready to paste"
comment *per candidate position* rather than per method, each
independently claiming *every* mandatory position was `fixnum`
regardless of whether that specific position had any evidence at all
(a 4-argument `#initialize` with only argument 2 confirmed would print
a comment claiming all 4). Fixed by grouping candidates per method and
building one combined signature per method, leaving every
unconfirmed position blank -- a real, already-supported partial
annotation (an empty token between commas parses to `nil` in
`Annotations::TYPES`, the same "no claim" an unrecognized token
already gets); also dropped the unfounded `-> T` return-type guess
entirely, since this tool only ever observes incoming *arguments*
(`TracePoint(:call)`), never a method's own return value.

Run for real against the whole project: of 71 live candidates, **26
are confidently resolvable to `fixnum`** from real observed evidence
(thousands of real calls for some, e.g. `LCF::Array1D#initialize`'s
`@schema` argument -- correctly reported as `Hash`, *not* annotatable,
17,196 real calls observed). The other 45 are either genuinely not
Fixnum-typed (confirmed by real evidence, not guesswork -- `Game::
State#initialize`'s `@party` argument is one of 30+ real `Party`
subclasses; `RGSS::ErrorReport::Tee#initialize`'s `@io` is `StringIO`/
`IO`/a custom sink) or have zero real coverage in this environment
(`LCF::Tree#initialize`'s two arguments are only reached by parsing a
real `RPG_RT.lmt` map-tree file, which this environment's `./data`
doesn't have -- an honest, traceable "no evidence" rather than a
guess). One real near-miss the dynamic approach caught that source-
reading alone would have missed: `RPG2k::Scene::SaveLoad#initialize`'s
second argument is `NilClass` 33 times and `Game::State` only 9 times
in real observed calls -- it would have looked like a plausible
Fixnum candidate from the name alone (`@state`) but isn't fixnum at
all, in either observed shape.

### Static consistency checking

One cheap static check *is* free and worth doing: wherever an annotation
and `ArgTypes`' own pooled inference independently cover the very same
name and position (a MONO, non-`#initialize` method that happens to be
annotated too), bc2cpp could compare the two and warn on disagreement --
a real, purely static contradiction check requiring no CRuby test run at
all, since both sides already come from the same closed-world bytecode
analysis. Not implemented in this pass (the two data sources barely
overlap in practice today, since `#initialize` -- where annotations
actually matter -- is exactly what `ArgTypes` can't reach), but a natural
small addition if annotations spread to non-`#initialize` methods too.

### The 26 real annotations, actually applied

Everything above built the mechanism and the profiler that suggests real
annotations; none had actually been written into real game source yet.
Applied all 13 methods (26 argument positions)
`profile_annotations.rb` confidently resolved to `fixnum` from real
observed evidence: `Game::Actor#initialize`, `Game::Map#initialize`,
`Game::Transition#initialize`, `Game::State#initialize`,
`Game::Screen#tint_to`/`#restore_tint`/`#shake`/`#flash`,
`Game::Interpreter#start_at`, `RPG2k::Scene::Map::LRUBitmapCache#initialize`,
`RPG2k::Scene::ItemMenu#prompt_item_target`, `LCF::EventCommand#initialize`,
`LCF::MoveCommand#initialize` -- each with the exact partial signature
(blank for any position the profiler didn't confirm) `profile_annotations.rb`
itself printed.

None of these classes are in either shipped compiled gem's own
`ONLY_OWNERS` (`LCF::File`-family, `Game::Picture`) -- same "real,
verified, zero *live* effect today" shape as the registry-soundness
follow-ups above, since `IvarLayout`'s own embedding analysis is a
whole-program pass regardless of what gets *emitted*. Real payoff
measured directly in that whole-program analysis, not by what either
compiled gem outputs: **158 -> 174 EMBED lines** (a true before/after,
`git stash`-based, not a stale reference) -- 16 real ivars newly
embeddable, several *not* directly annotated at all (`Game::Actor#@exp`/
`@level`/`@faceset_index`/..., `Game::Screen#@shake_power`/`@fade`/`@pan_x`/
...) but unlocked as a side effect of the same fixed-point analysis
`IvarLayout` already runs: once one opaque-argument ivar in a class
resolves to `fixnum`, every other ivar in that same class that derives
from it (an `ADD`/`ADDI` on it, or a `GETIV` read of it feeding another
`SETIV`) can now resolve too.

Re-verified both already-shipped targets unaffected the same rigorous
way, with one real, understood wrinkle worth recording: `LCF::File`-
family's own generated output came out **fully byte-identical** (its
methods live in `mruby-lcf/mrblib/lcf_file.rb`/`schema.rb`, files this
round never touched), but `Game::Picture`'s own output showed lines
differing only in the *source line number* a disassembly-echo comment
reports (e.g. `// 8686 000 ENTER ...` became `// 8693 000 ENTER ...`) --
adding 7 real `# bc2cpp:` comment lines earlier in the very same file
(`game.rb`, where `Game::Picture` is also defined) shifts every real
source line number after them by exactly that many, and `mrbc`'s own
disassembly always reports the *real* line a bytecode instruction came
from. Confirmed mechanically, not by eye, that this is the *entire* diff
and nothing else changed: stripping every line matching that one comment
pattern from both sides of the diff left zero remaining differences.
Real, expected, and inert -- a comment can never itself emit bytecode --
but it means "byte-identical" isn't quite the right bar for a change
that (unlike every earlier bc2cpp follow-up) edits real, shipped mrblib
source directly rather than only `bc2cpp.rb`/`mrbgem.rake`; "identical
except for line-number echoes in comments, mechanically confirmed" is.

One real process mistake surfaced and corrected while re-deriving these
numbers, worth recording so it isn't repeated: several of this session's
own earlier ad hoc verification commands used a bare shell `ls
mruby-rpg2k/mrblib/**/*.rb` to approximate the real closed-world source
list. Bash's own `**` glob (without `shopt -s globstar`, not set in this
environment) only matches *inside* at least one subdirectory -- it
silently drops any file directly in `mrblib/` itself, which is exactly
where `game.rb`, `interpreter.rb` and `main.rb` live. The real
`mrbgem.rake` files were never affected (they use Ruby's own `Dir[]`,
which has no such restriction, confirmed directly:
`Dir["mruby-rpg2k/mrblib/**/*.rb"]` correctly includes all three), and
every number this ADR actually shipped on was always double-checked
through the real `rake` build path before being trusted -- but a few
*intermediate*, never-shipped-on diagnostic numbers quoted in
conversation earlier in this session (a leaf-method/`#error` count in
particular) were computed against this same incomplete file list by
hand and are undercounts of the real, complete closed world.
`profile_annotations.rb` itself was never affected either -- it always
used `Dir[]`, not a shell glob.

### 75 more annotations: readability, not just ivar embedding

The evidence-based approach above had exhausted itself: re-running
`profile_annotations.rb` found 0 further `SETIV`-derived candidates
confirmable to `fixnum` (every one of the 43 remaining positions from
before came back with real, solid evidence of a *different* concrete
class -- `Game::Party`, `String`, `Symbol`, booleans, `Hash`, ... --
correctly reported "not annotatable" rather than silently dropped).
Asked directly to keep annotating "since it helps a lot when I read the
actual code," not just for `bc2cpp`'s own compiler payoff, which opened
a real, previously-unused source of evidence: `report_annotation_
candidates` only ever looked at `SETIV` sites (the one place an
annotation can change compiled output, via `IvarLayout`), never at an
opaque mandatory argument consumed directly by a fixnum-fastpath
arithmetic/comparison op (`ADD`/`SUB`/`EQ`/`LT`/`LE`/`GT`/`GE` and their
`*I` immediate forms) with no `SETIV` anywhere in sight -- e.g.
`def battler_z(i); 100 + (... - 1 - i); end`, `i` never once touching an
ivar. Annotating one of these can never change compiled output
(`IvarLayout.trace_type`, the only consumer of `arg_types`/`annotations`,
only ever reaches its "incoming argument" fallback from a `SETIV`
trace), but it's exactly the kind of real, evidence-backed fact worth
writing right above a `def` for a human reader -- and it's what a
`# bc2cpp: (...)` comment already looks like, so no new syntax was
needed, just a second scan.

`report_annotation_candidates` (`tools/bc2cpp/bc2cpp.rb`) and
`profile_annotations.rb` were extended to find and profile these too
(caught and fixed a real bug surfaced along the way: mixing named and
plain capture groups in one Ruby regex silently makes every plain group
non-capturing, which had renumbered `owner`/`name`/`pos`/`mand` out from
under `profile_annotations.rb`'s own parser -- every group is named now).
148 total candidates (up from 43 -- 105 new arithmetic-derived ones), of
which the same real-harness profiling run resolved **92 positions across
75 methods** confidently to `fixnum`, spanning `Game::Actor`/`Actors`/
`EnemyAi`/`ChipSet`/`Map`/`Transition`/`Screen`/`Interpreter` and
`RPG2k::Scene::Base`/`Battle`/`Order`/`SaveLoad`/`ItemMenu`/`Title` --
applied directly to the real source, each comment placed at the exact
`irep.file`/`enter.lineno` bc2cpp's own registry already names for that
`def` (no separate lookup or guessing).

Verified the same way as every other real-source change in this file:
`ruby -c` on all 10 touched files; whole-program `EMBED` count unchanged
at 174 (expected and correct -- none of these 92 positions ever reaches
a `SETIV`, so none could newly unlock an embedding, by construction);
both already-shipped compiled targets re-checked against a true
`git stash`-based before/after -- `LCF::File`-family byte-identical,
`Game::Picture` identical except for disassembly-echoed line-number
comments (the same inert, mechanically-confirmed-only-that shift the
first annotation round already documented, since these new comments
also land in `game.rb`); all four real CRuby harnesses
(`rpg2k_logic_check.rb`: 1201 checks, `rpg2k_scene_check.rb`: 1062 checks,
`error_report_check.rb`, `rgss_cruby_test_check.rb`) still pass. Purely
additive to the codebase's own readability -- zero compiled-output
effect today, by design, same honest framing as every other "real,
verified, no live payoff yet" finding in this file.

## Follow-up: cross-gem devirtualization

`compile_send`'s own guard already refused to devirtualize a call whose
target's owner wasn't in this run's `ONLY_OWNERS` (the real
`LCF.write_ber`/`LCF.binstr` bug this ADR documents above) -- but the
deeper reason was structural, not just that guard: every `_impl` function
was `static`, so even *without* the guard, a devirtualized call from
`mruby-rpg2k-compiled`'s own generated `.cpp` into
`mruby-lcf-compiled`'s own compiled `LCF::Array1D#delete` (the README's
own aspirational example) could never have linked -- `static` gives a
function internal linkage, invisible outside its own translation unit.
Each compiled gem's generated file is its own separate TU, so this made
cross-*gem* devirtualization structurally impossible before this pass,
independent of the `ONLY_OWNERS` guard.

Explored a parallel "unwrapped core" design first (a raw-C++-typed
`_core` alongside the existing `mrb_value`-boxed `_impl`, `inline` in a
shared header, so a caller with an already-proven-typed value could skip
boxing it into `mrb_value` just to have the callee immediately unbox it
again). Didn't build it: this compiler's entire internal representation
is uniformly `mrb_value` -- every register is already a boxed
`mrb_value` local, and `_impl`'s own body would still need to re-box a
raw incoming argument into one on its very first line either way (the
same "goto-threaded, straight-line, always-`mrb_value`" codegen strategy
this whole prototype uses throughout). A `_core` variant taking a raw
`mrb_int` would save nothing real under this design -- the actual,
concrete blocker was always the linkage problem, not boxing. Making
`_core` genuinely pay off would mean giving the whole register
representation real, tracked C++ types end to end, a materially bigger
rewrite than this pass attempts -- noted here so this exploration isn't
silently repeated.

What actually shipped: `_impl` (and its own declaration) dropped
`static` -- real, external linkage, the minimum change needed to make a
cross-TU call possible at all. The entry wrapper (`mrb_get_args`
marshaling) stayed `static`; nothing outside a gem's own registration
code ever calls it. A new `emit_decls_header` emits a standalone,
`#pragma once`-guarded header of the same non-static declarations
(written to `OUT_DIR/<symbol>_decls.h` on every run, unconditionally --
cheap, and a given run doesn't know in advance whether anything will
ever reference it). Two new env vars, mirroring `ONLY_OWNERS`'s own
shape: `OTHER_OWNERS` (classes this run trusts *some other* gem's own
run to compile -- widens `compile_send`'s owner guard for devirtualizing
into them, without adding them to this run's own emitted output) and
`OTHER_DECLS_HEADER` (real file paths this run `#include`s so those
classes' declarations are actually in scope).

A new `tools/bc2cpp/compiled_gems.rb` is the single source of truth both
`mrbgem.rake`s now `require_relative` -- each compiled gem's own target
owners and `OUT_SYMBOL`, keyed by gem name. Each `mrbgem.rake` computes
its own `OTHER_OWNERS`/`OTHER_DECLS_HEADER` from every *other* entry
there, rather than hardcoding the sibling gem's owner list directly (real
drift risk otherwise). `register.cxx`'s own `file` dependency grew to
include every other compiled gem's own generated file too -- not because
this gem's own codegen needs to *read* that file (`OTHER_OWNERS` is
static config, known without it), but because this gem's own `#include`
of the other's `*_decls.h` (written as a side effect of the other's own
codegen run) needs that file to actually exist by the time this
translation unit is compiled. Depending on the other's `generated` (the
`.cpp`) rather than nothing at all from `register.cxx` specifically --
never from `generated` itself -- keeps this a DAG: neither gem's own
codegen step ever waits on the other's, so two compiled gems each
naming the other in `OTHER_OWNERS` can't deadlock Rake.

Verified for real, three ways, using the actual project build
(`RPGMAKER_BC2CPP=1`, both real compiled gems wired to trust each
other):
1. Both gems' own `bc2cpp.rb` runs still succeed and each emits a real
   `#include "/abs/path/to/the/other/gem/<symbol>_decls.h"` line, with
   **zero other change** to either gem's own generated output (confirmed
   by diffing against the pre-cross-gem run -- the only diff in either
   file is that one new `#include` line).
2. `rake .../mruby-lcf-compiled/src/register.pi
   .../mruby-rpg2k-compiled/src/register.pi` -- a real, targeted
   compile of both translation units -- succeeds with **zero errors or
   warnings**, proving the mutual header inclusion and the Rake
   dependency graph (no cycle) both actually work, not just plan cleanly
   on paper.
3. A full real host build, `rake .../host/lib/libmruby.a` with
   `RPGMAKER_BC2CPP=1` (every real gem, `mruby-lcf-compiled` and
   `mruby-rpg2k-compiled` included, both now non-static) -- succeeds,
   archives cleanly. `nm -C` on the result shows exactly 41 external
   (`T`) `_impl` symbols and 41 local (`t`) entry symbols from these two
   gems, one of each per compiled method, no duplicates -- confirming
   dropping `static` introduced no real symbol-collision risk in
   practice (`cpp_name`'s `::`-to-`_` collapsing is theoretically
   collision-prone across two *different* real owners that happened to
   sanitize to the same string, but this project's actual namespacing
   -- `RGSS::`/`RPG2k::`/`LCF::`/`Game::`, gem-specific prefixes that
   never overlap -- makes that implausible in practice, and it was
   already an equally real risk *within* a single gem's own TU before
   this change, just never yet hit).

No real cross-gem devirtualized call actually appears in either
shipped target's own output, same "verified sound, zero live effect"
result as the native-method-registry and magic-comment-annotation
follow-ups above: neither `LCF::File`-family nor `Game::Picture` (the
only two real target classes compiled today) happens to call into the
other's own target set from a compiled method body. The mechanism is
real and now provably works end to end; it simply has nothing to bite
into yet with only two, non-overlapping compiled gems.

## Follow-up: mruby core native method registry extraction

The RGSS native-registry follow-up above closed the registry-soundness
gap for RGSS's own C++-implemented methods. The exact same class of gap
exists against mruby's *own* core (`Array`/`Hash`/`String`/`Kernel`/
`Symbol`/...) -- and it was still wide open, because mruby's own C
source doesn't register its methods the way `mruby-rgss/src/lib.cxx`
does.

Confirmed by reading the real source, not assumed: mruby 4.0 registers
most of its own core methods through a declarative ROM method-table
macro instead of individual `mrb_define_method(klass, "name", ...)`
calls -- e.g. `3rd/mruby/src/symbol.c`'s own `symbol_rom_entries`:
```c
static const mrb_mt_entry symbol_rom_entries[] = {
  MRB_MT_ENTRY(sym_name, MRB_SYM(name), MRB_ARGS_NONE()),
  MRB_MT_ENTRY(sym_cmp,  MRB_OPSYM(cmp), MRB_ARGS_REQ(1)),   // <=>
  ...
};
MRB_MT_INIT_ROM(mrb, sym, symbol_rom_entries);
```
`Symbol#name`/`Class#name` -- exactly the two names behind this
session's own earlier-caught `Game::Shop#name` bug -- are registered
this way. `extract_native_method_names`'s original regex, built only
against RGSS's own literal-string call shape, could never see this at
all: pointing `NATIVE_SRCS` at mruby's own core source wouldn't have
found a single name without also teaching the extractor this second,
completely different registration idiom.

Two more regex patterns cover it: `MRB_MT_ENTRY(fn, MRB_SYM(name)|
MRB_OPSYM(op), flags)` (the ROM-table form above) and
`mrb_define_method_id(mrb, klass, MRB_SYM(name)|MRB_OPSYM(op), func,
aspec)` (the direct-call form a few core mrbgems, e.g. `mruby-task`,
still use instead of a ROM table). `MRB_OPSYM(op)` needed one more
piece: it spells an operator method in mruby's own internal C-safe
token, never the operator text itself (`MRB_OPSYM(cmp)` means `<=>`,
never literally "cmp") -- `extract_native_method_names` now carries the
inverse of `3rd/mruby/lib/mruby/presym.rb`'s own `OPERATORS` table (a
small, closed, finite list -- mruby's own presym generator has no other
source of truth for this mapping either) to translate it back to the
real Ruby name the registry actually keys on.

`mruby-lcf-compiled`/`mruby-rpg2k-compiled` now also feed
`NATIVE_SRCS` with `3rd/mruby/src/*.c` plus the C sources of every core
mrbgem `build_config.rb` actually enables (`mruby-array-ext`,
`mruby-hash-ext`, `mruby-enum-ext`, `mruby-io`, `mruby-dir`,
`mruby-numeric-ext`, `mruby-range-ext`, `mruby-fiber`, `mruby-exit`,
`mruby-sprintf`, `mruby-kernel-ext`, `mruby-random`, `mruby-math`,
`mruby-time`, `mruby-bigint`) -- a new `core_native_srcs` helper in
`tools/bc2cpp/compiled_gems.rb`, the same shared file both gems already
`require_relative` for their owner lists, so the core-gem list has one
place to stay in sync with `build_config.rb`'s own `conf.gem core:
'mruby-xxx'` calls.

Run against the whole real closed world: 469 native names extracted
(up from 115 RGSS-only), **27 real collisions found** against the
current `mruby-rpg2k`+`mruby-lcf`+`mruby-rgss` mrblib set (up from the
6 RGSS-only ones) -- the previous 6 (`:x`/`:y`/`:width`/`:height`/
`:ox`/`:oy`) plus 21 more entirely new ones against mruby's own core,
including a genuinely serious one: `LCF::Array1D#delete` colliding
with core `Array#delete`/`Hash#delete` -- this tool's own README
example (`Game::Actor#forget_skill`'s `@skills.delete(skill_id)`
devirtualizing into `LCF::Array1D#delete`) was only ever safe because
`@skills` really is always an `Array1D` there; before this fix, *any*
other `.delete` call anywhere in the whole program on a real `Array`/
`Hash` would have been unsoundly devirtualized into `LCF::Array1D`'s
own implementation instead of core's. Others: `:puts`/`:print`/`:write`/
`:<<` (`RGSS::ErrorReport::Tee` vs. `Kernel`/`IO`), `:resume`/`:start`
(`RPG2k::Scene::Menu`/`Battle` vs. `Fiber`), `:ungetbyte` (`StringIO`
vs. core `IO`).

Verified sound and zero-regression the same way as every other native-
registry change in this file: a real toy case (a new `MRB_MT_ENTRY`/
`MRB_SYM`/`MRB_OPSYM`-shaped fixture colliding with `Sized#n`, plus a
literal `MRB_OPSYM(cmp)` entry confirming the operator-table
translation) flips exactly as expected; both already-shipped targets
(`LCF::File`-family, `Game::Picture`) emit **byte-identical** output
through the real Rake build path, confirmed against a true `git
stash`-based before/after (not a stale reference) -- neither currently
calls any of the 27 flipped names from a compiled call site, so this
is, once again, a real, verified safety fix with zero live effect on
what ships today.

## Follow-up: call-site type-based devirtualization

Every devirtualization decision up to this point (`monomorphic_target`)
is purely NAME-based: a method name with exactly one definition anywhere
in the whole program. A genuinely POLY name (`:speak` on `Animal`/`Dog`/
`Cat`, say) always falls back to `mrb_funcall`, even at a specific call
site where the receiver's *exact* runtime class happens to be provable
from the surrounding code.

`bc2cpp` has no representation of Ruby class inheritance/superclass
relationships at all -- `build_registry`'s own `CLASS`/`MODULE`/`EXEC`
walk only tracks flat namespace nesting for fully-qualified naming
(`Game::Actor`, never "Actor extends Object"). Building real MRO
(method-resolution-order) modeling to ask "which class might this
receiver be" is a substantial undertaking on its own. A narrower
question turns out not to need any of that, though: "is this receiver
POSITIVELY, EXACTLY one statically known class" -- answerable, in the
one case where Ruby itself guarantees it, by tracing a `.new` call.
`SomeClass.new` always allocates the literal receiver class it's sent
to, never a subclass in disguise, so a call site whose receiver traces
back to a *fresh* `SomeClass.new(...)` earlier in the same straight-line
method body can be matched directly against `SomeClass`'s own
definition -- no superclass walk needed, and never unsound: a method
`SomeClass` merely *inherits* (rather than defines itself) has no
matching registry entry and simply stays a safe miss, same as any other
unresolved call site.

New top-level `trace_new_target(irep, idx, reg)` implements this: walk
backward from a SEND's own position (same backward-scan idiom as
`IvarLayout.trace_type`, following `MOVE` chains), and when the last
write to the receiver register is itself a `SEND0/SEND :new`, keep
tracing the *same* register one step further for a `GETMCNST*/GETCONST`
constant-path chain (mirrors `GETMCNST`'s own codegen: it reads a
constant off of its base register and overwrites it in place, so each
segment's own base is still findable one step further back) -- e.g.
`Zoo::Bird.new` compiles to `GETCONST Zoo; GETMCNST (·)::Bird; SEND0
:new`, and the trace reconstructs `"Zoo::Bird"` by walking that chain
outside-in. `compile_send` only tries this when name-based resolution
already failed (still POLY) and the call has an explicit receiver (never
for `self.foo`/`SSEND` -- a real `Animal` instance could actually *be* a
`Dog` or `Cat` at runtime, so tracing "what was self assigned from" is
never sound the way tracing a fresh local is). A hit emits a `TYPED`
comment (distinct from `MONO`/`POLY`) so it stays visible in output/
verification, otherwise everything falls through to the exact same
`pure_mandatory_arity?`/`ONLY_OWNERS`/`OTHER_OWNERS` guards the MONO
path already uses.

Verified with a new toy case (`docs/adr/0139` toy harness): `Dog.new
("Rex").speak` and `Zoo::Bird.new.speak` (`:speak` genuinely POLY, 4 real
definitions across the toy program) both devirtualize to their exact
class's own `_impl` -- confirmed by a true before/after diff (only those
two lines change) and by actually running the built C++ harness:
`Woof`/`Tweet` come back correct (not misdispatched to `Animal#speak`,
the wrong "first match"), byte-identical to plain `ruby toy.rb`. The
negative case (`Animal#greet`'s own `self.speak`) was checked too --
confirmed it stays real `mrb_funcall` dispatch, unchanged.

Run against the whole real closed world (same `mruby-rpg2k`+`mruby-lcf`+
`mruby-rgss` mrblib set as every other whole-program measurement in this
file, no `ONLY_OWNERS` restriction -- 721 compiled methods, 940 MONO
direct calls, 1608 POLY `mrb_funcall` sites): **zero** real `TYPED` hits.
Both already-shipped targets (`LCF::File`-family, `Game::Picture`) are,
once again, **byte-identical** through the real Rake build path against
a true `git stash`-based before/after. Read honestly rather than
declared a win: the pattern this slice targets -- construct locally,
immediately call a *genuinely polymorphic* name, all in the same
straight-line body -- doesn't occur anywhere in this codebase's own
currently-compilable (opcode-subset) method bodies. A `SomeClass.new.
method` chain where `method` happens to be POLY is intrinsically rare
next to a `SomeClass.new.method` chain where it's already MONO (already
devirtualized, not counted here) or where the constructed value is
instead stored into an ivar/local and consumed from a *different*
method (structurally invisible to a same-body backward scan, the same
boundary `ArgTypes`' own comment already documents for constructor
arguments). Kept anyway: it's sound, fully verified, zero-regression
infrastructure that a future whole-program extension (tracing a
receiver's type through an ivar read the way `IvarLayout` already proves
ivar *primitive* types, or through an argument the way `ArgTypes`
already proves argument primitive types) could build on -- but, as
measured today, it has no live payoff on this project's real code.

## Follow-up: Symbol-ivar embedding

`IvarLayout`'s embedding analysis only ever modeled one primitive type,
Fixnum (`C_TYPE = { fixnum: 'mrb_int' }`) -- a literal Symbol source
(`@tag = :ok`, mruby's own `LOADSYM` opcode) fell through `trace_type`'s
generic "some instruction we don't specifically model" fallback straight
to `UNKNOWN`, same as any genuinely opaque value. Asked directly whether
mruby's own `Symbol` is garbage-collected -- worth confirming before
embedding one as a raw field, the same soundness question every other
embeddable type in this file already answers -- and it's not: read
directly from `3rd/mruby/include/mruby/value.h` (`typedef uint32_t
mrb_sym`, a plain integer, never `RBasic`-derived) and
`3rd/mruby/src/symbol.c`/`state.c` (`mrb_free_symtbl` -- the *only* place
mruby's own symbol table is ever freed -- is called exactly once, from
`mrb_close`'s own state-teardown path, never from `gc.c`'s mark-and-sweep).
An interned symbol lives for the whole `mrb_state`'s lifetime once
created; there is no per-symbol GC event a struct field embedding one
could ever race with -- exactly the same guarantee `mrb_int` already
relies on for Fixnum, just for a different C type.

Extended the same mechanism Fixnum already uses, not a parallel one:
`IvarLayout.trace_type` gained a `LOADSYM` case (returns `:symbol`,
mirroring the `LOADI`/`:fixnum` case exactly); `Annotations::TYPES`
recognizes `symbol`/`Symbol` tokens now too; `CodeGen::C_TYPE` maps
`:symbol -> 'mrb_sym'`; and the `GETIV`/`SETIV` codegen, previously
hardcoded to `mrb_fixnum_value`/`mrb_integer_p`/`mrb_integer`, now goes
through a small `TYPE_OPS` table (`box`/`check`/`unbox`/`err` per type)
so both primitive types share one code path -- a real Symbol write still
gets the same guarded, `mrb_raise`-on-mismatch treatment as a Fixnum one,
just checked with `mrb_symbol_p`/unboxed with `mrb_symbol` instead. This
also means `ArgTypes` (which reuses `trace_type` unmodified) started
reporting real `Symbol`-typed call-site argument positions for free, no
separate change needed.

Verified with a new toy case (`Tagged#@tag`, always a literal Symbol):
generated a real `mrb_sym tag;` struct field, a `mrb_symbol_p` guard, and
`mrb_symbol`/`mrb_symbol_value` box/unbox calls exactly as designed;
built, linked, and ran it through the real toy harness -- `tag`/`tag=`
round-trip an embedded Symbol correctly (`ok` -> `changed`), byte-
identical to plain `ruby toy.rb`. Both already-shipped compiled targets
re-checked byte-identical (neither has a Symbol-typed ivar today). Real
whole-program payoff: **174 -> 184 EMBED lines**, ten real UI-state mode/
focus Symbol ivars across `RPG2k::Scene::ChipsetEditor`/`DebugMenu`/
`EquipMenu`/`ItemMenu`/`MapViewer`/`Menu`/`Order`/`SkillMenu` (e.g.
`@mode`, `@focus`, `@tab`, `@brush_layer`) -- none of these classes are
in either shipped compiled gem's own target set, so (same shape as every
other whole-program-only follow-up in this file) no *live* effect on
what ships today, but a real, sound, doubly-verified capability the next
compiled target can draw on for free.

## Follow-up: guarded class-type devirtualization

The earlier call-site type-based devirtualization follow-up only ever
traced a receiver back to a fresh, *same-body* `SomeClass.new(...)` --
found zero real hits, because the actual dominant real pattern turned
out to be different: an *ivar* holding a known-class object constructed
or received elsewhere (`@state.foo`), not a local freshly built right
before use. `profile_annotations.rb` had the real evidence for this the
whole time -- it already records every profiled argument's real
observed class, for *every* candidate, not just the ones that turn out
to be `Integer` -- but `report()` only ever acted on the Integer case,
silently discarding a `classes.size == 1` result for any other real
class (e.g. `Game::EnemyAi#initialize, arg 2/2 -> @state: Game::State:
315 -- not annotatable`, printed and thrown away in an earlier run of
this same tool).

Two new pieces, both deliberately kept separate from `IvarLayout`'s own
embedding lattice (a known object class is never a struct-field
candidate -- still a real `mrb_value` pointing to a real heap object,
nothing to unbox; letting one reach `C_TYPE.fetch` would be a real
`KeyError` at codegen time):

- **`ClassAnnotations`**: a second, independent reader of the exact
  same `# bc2cpp: (...)` comment syntax `Annotations` already uses --
  `# bc2cpp: (Game::State)` on `#initialize` claims "this mandatory
  argument position is always exactly this one real class." Each reader
  silently ignores tokens it doesn't recognize (a class-shaped token
  already no-ops in `Annotations::TYPES`; a primitive token no-ops
  here), so one line can freely mix both:
  `# bc2cpp: (Game::State, fixnum)`.
- **`ClassLayout`**: the object-reference analogue of `IvarLayout` --
  a whole-program, fixed-point "this ivar always holds an instance of
  exactly this real class" analysis. Its own SETIV trace is
  `trace_new_target` itself, extended with a `GETIV` case (an ivar
  ClassLayout already knows the class of) and an opaque-argument
  fallback (a `ClassAnnotations` hint) -- so `@resident = Dog.new` and
  `@pet = pet` (with `pet` annotated `Game::Dog`) both teach `ClassLayout`
  the same fact, and either can feed a *later* method's own
  `@resident.speak`/`@pet.speak`.

`compile_send` uses this whenever name-based devirtualization still
comes up POLY. Unlike the original same-body `.new` case (a hard Ruby-
semantics guarantee -- `.new` never allocates a subclass in disguise),
an ivar's or annotation's class fact is a real whole-program observation,
not a proof: this compiled run can't see every possible writer (a future
uncompiled caller, reflection), and a `ClassAnnotations` hint is human-
asserted. So every hit through this path -- including the original
same-body `.new` case, extended for free and costing nothing there since
the check is simply always true -- now emits a real runtime
`mrb_class_ptr(<chained mrb_const_get>) == mrb_obj_class(M, recv)` guard
before the direct call, falling back to ordinary `mrb_funcall` if it
doesn't match. Strictly *safer* than the name-only MONO devirtualization
above it, which trusts the registry with no runtime check at all.

**Two real bugs caught while building this, both fixed, neither
previously live** (verified: byte-identical on both already-shipped
compiled targets before and after each fix):

1. `trace_new_target`'s `GETCONST`/`GETMCNST` cases fired unconditionally
   -- reachable even when the register's last write was a *bare*
   constant reference with no `.new` anywhere in sight (`@position =
   POS_BOTTOM`, a plain Integer). Running the extended analysis against
   real game source surfaced this immediately as obviously-wrong
   `CLASS_HINT`s (`Game::MessageConfig#@position (POS_BOTTOM)`,
   `Game::NumberInput#@digits (MAX_DIGITS)`, ...) -- neither is a class.
   Fixed with a `resolving_new` flag: `GETCONST`/`GETMCNST` are only
   ever valid once a `SEND :new` has actually been seen on this same
   register first.
2. `GETCONST`'s own name extraction (`a.split(/\s+/, 2)[1]`, in both the
   real codegen and the new `trace_new_target` case) captured a
   trailing local-variable-name comment too whenever the destination
   register is a named local (`GETCONST R3 MAX_DIGITS\t; R3:d`, real
   disassembly shape) -- a pre-existing bug in the *already-shipped*
   `GETCONST` codegen, not something this round introduced, caught only
   because building `ClassLayout` finally exercised it. 16 real
   occurrences in the whole closed world (none inside either shipped
   compiled target's own methods, confirmed by owner -- a real, live-
   but-dormant bug: it would raise a genuine `NameError` at runtime, not
   caught by any `#error` check, the moment a currently-uncompiled
   method with this exact shape ever got added to a compiled target).
   Fixed by extracting `\S+` (stops at the first whitespace/tab) instead
   of the rest of the line, in both places.

Verified with new toy cases: `Kennel#@resident` (static `.new`-sourced
ivar) and `Handler#@pet` (a `# bc2cpp: (Dog)`-annotated opaque argument)
both devirtualize `#wake`/`#greet`'s own `@resident.speak`/`@pet.speak`
through the new guarded path -- built, linked, and run for real (`Woof`/
`Woof`, byte-identical to `ruby toy.rb`); a negative case
(`BadTagUser#@label = BAD_TAG`, a bare Integer constant, exercising bug
#1 directly) correctly stays ordinary `POLY` dispatch, no bogus
`CLASS_HINT` at all. Real whole-program payoff: **34 real `TYPED` hits**
(up from 0) purely from the static `GETIV` extension, spanning
`Game::Rng#random`, `Game::Interpreter#resume/start/update`,
`Game::Character#x=/y=`; applying 21 real profiled class annotations to
actual source (8 recognized by `ClassLayout` as real registry owners,
the rest -- `Symbol`/`String`/`Hash`/`Array` -- harmless pure
documentation, since none of those are real owners in this closed world)
raised it to **35** and grew `CLASS_HINT` from 82 to 92. Both already-
shipped compiled targets remain byte-identical (or cosmetic-line-number-
echo-only, mechanically confirmed) throughout; all four real CRuby test
harnesses still pass. A pre-existing, unrelated gap surfaced while
syntax-checking the *unrestricted* (no `ONLY_OWNERS`) whole-program
output for real with `g++ -fsyntax-only` -- 434 undefined-reference
errors, identical in count with and without this round's changes, from
MONO devirtualization never checking whether its own target's irep will
actually be *emitted* (a callee dropped by `SKIP_UNSUPPORTED` for an
unrelated opcode gap still gets called by name). Confirmed orthogonal
and pre-existing (reproduces identically against the unmodified tool);
never live, since the real build always sets `ONLY_OWNERS`. Not fixed
here -- flagged for whoever next touches `compile_send`'s own MONO path.

Real per-position class annotations applied this round: `Game::EnemyAi#
initialize`, `Game::Interpreter#initialize`, `RPG2k::Scene::VehicleWorld#
initialize`, `RPG2k::Scene::Battle#initialize`, `RPG2k::Scene::DebugMenu#
initialize`, `RPG2k::Scene::ItemMenu#initialize`, `RPG2k::Scene::Menu#
initialize`, `RPG2k::Scene::Order#initialize` (all `Game::State`/`Game::
Rng`/`Game::Interpreter`/`RPG2k::Scene::Map`-typed), plus
`LCF::Array1D/Array2D#initialize`, `RGSS::Bitmap::LoadError#initialize`,
`Game::Actor#set_charset`, `Game::State#set_parallax/set_system_graphic`,
`Game::Interpreter#resume_battle`, `RPG2k::Scene::MapWorld#play_sound`,
`RPG2k::Scene::Battle#enter_battle_result/battle_result_lines`,
`RPG2k::Scene::Menu#wait_term_for/enter_actor_selection` (documentation-
only: `String`/`Hash`/`Symbol`/`Array` aren't real registry owners here).
Three real candidates (`Game::Actor#initialize`, `LCF::EventCommand#
initialize`, `LCF::MoveCommand#initialize`) were skipped rather than
applied -- each already carries a real fixnum annotation from an earlier
round, and merging a class hint into an existing partial signature was
left alone rather than risk clobbering good data for a low-value case
(one of the three is a test-fixture class, not even real).

## Follow-up: coverage expansion (Game::EnemyAction, RGSS::Sprite)

Two gaps kept whole real classes out of reach regardless of any single
opcode: `build_registry` treated `#initialize`/`#initialize_copy`/
`#respond_to_missing?` like any other method, registering them at
whatever visibility the *source* happens to have around the `def` --
wrong, because mruby's own `mrb_define_method_raw` (`src/class.c`,
around line 1044) special-cases exactly these three names, forcing
`MRB_METHOD_PRIVATE_FL` regardless of the flags passed in, unconditionally,
for every class in the language, not just this codebase's own. Confirmed
both by reading that code path and empirically: a toy `Foo#initialize`
with no `private` anywhere in sight still raises `private method
'initialize' called for Foo` the moment `f.initialize` is called from
outside, under the real interpreter. `build_registry` now models this
rule directly instead of trusting the source's own visibility state for
these three names.

The second gap was opcode coverage: `JMPNIL` (`OP_JMPNIL`, `src/vm.c` --
`@ivar.nil? ? default : @ivar`'s own compiled shape, common in plain
Ruby accessor methods) and `LOADL` (`OP_LOADL` -- a float-pool literal
too wide for `LOADI`'s immediate operand) had no `compile_insn` case at
all; `SKIP_UNSUPPORTED` silently dropped every method built from either
one. Both are narrow, mechanical additions (`JMPNIL` reuses the same
jump-target bookkeeping as `JMPNOT`/`JMPIF`; `LOADL` only supports a
float pool entry, `#error`-ing on anything else, mirroring `LOADI8`/
`LOADI16`'s own established pattern for out-of-range integers).

`GETCONST`'s own codegen (both the real emitted case and
`trace_new_target`'s copy of it) only ever tried one scope -- `Object`,
unconditionally -- for a bare constant lookup. That is wrong whenever
the constant is actually defined on the *enclosing* module rather than
top-level (`RGSS::Sprite#tone`'s own `Tone.new(...)`: `Tone` lives under
`RGSS`, not `Object`). Rewritten to walk the owner's own real lexical
nesting chain, innermost first, via the `bc2cpp_const_try`/
`mrb_protect_error`-based helper the class-devirtualization follow-up
above already introduced for this same purpose, falling through to an
unprotected `Object` lookup only once the whole chain is exhausted (the
one case genuinely safe to let raise). Folded into the same case is this
round's own re-discovery that this file's `GETCONST` name-extraction fix
(the `trace_new_target`-side half, from the follow-up above) had never
actually been mirrored into the *emitted-code* side of the same opcode
-- fixed identically, `a[/^R\d+\s+(\S+)/, 1]` in both places again.

**Two new real compiled targets.** `Game::EnemyAction`
(`mruby-rpg2k/mrblib/game/battle_support.rb`) adds its own six real
bytecode-defined methods (`#initialize`, `#skill?`, `#transform?`,
`#basic?`, and the private `#int_of`/`#bool_of` helpers `attr_reader`
itself doesn't cover) to the existing `mruby-rpg2k-compiled` gem
alongside `Game::Picture`. `RGSS::Sprite` (`mruby-rgss/mrblib/lib.rb`,
the plain-Ruby reader methods it reopens the native `Sprite` class with)
gets a brand new `mruby-rgss-compiled` gem, all 17 of its own real
bytecode-defined accessors (`opacity`/`zoom_x`/`zoom_y`/`blend_type`/
`tone`/`color`/`width`/`height`/`x`/`y`/`z`/`ox`/`oy`/`angle`/`mirror`/
`bush_depth`/`src_rect`) -- the writers and `#initialize` stay native
C++ (`mruby-rgss/src/lib.cxx`), invisible to `bc2cpp` the same way every
other native method in this codebase already is. Both targets needed
the `JMPNIL`/`LOADL`/`GETCONST` work above to compile clean; neither
embeds any ivar (no compilable `#initialize` to allocate a struct in,
for either), so both stay on the ordinary dynamic `iv_tbl`, unchanged
from the interpreter's own behavior.

**Verified for real, independently re-measured (not copied from any
earlier estimate):** the real, opt-in `RPGMAKER_BC2CPP=1` build
(`rake .../host/lib/libmruby.a`) succeeds end to end against the actual
project sources, and `nm -C` on the resulting `libmruby.a` shows all 23
new entry points (17 `RGSS__Sprite_*_impl`, 6 `Game__EnemyAction_*_impl`)
present and externally linked. Syntax-checking the full, unrestricted
(no `ONLY_OWNERS`) closed-world output with `g++ -fsyntax-only` --
the same check that found the pre-existing 434-error gap two follow-ups
up -- now reports **421** errors, not 434: a real 13-error reduction from
this round's own opcode/GETCONST work letting more call sites resolve
their callee cleanly, not a regression. The same run emits **1,514**
real `_impl` method bodies across the whole closed world. Both already-
shipped compiled targets (`LCF::File`'s subclasses, `Game::Picture`)
remain unaffected; the 434-error gap itself is still exactly as
described above -- orthogonal, pre-existing, and never live, since the
real build always sets `ONLY_OWNERS`.

## Follow-up: Game::Screen, RPG2k::Window, and closing the devirtualization-soundness gap

Two more classes, covered in parallel this round and integrated together:
`Game::Screen` (screen tint/shake/flash/pan/fade effects,
`mruby-rpg2k/mrblib/game.rb`) and `RPG2k::Window` (the RPG2000-style UI
window -- skin/frame/cursor/contents/arrow rendering via four layered
`Sprite`s in a `Viewport`, `mruby-rpg2k/mrblib/main.rb`). Both landed in
the existing `mruby-rpg2k-compiled` gem alongside `Game::Picture`/
`Game::EnemyAction`.

**Four new opcodes**, all narrow and mechanical, same established
pattern as every prior round: `LOADSELF` (`self.foo = ...`, an explicit-
receiver self-send mrbc doesn't fold into `SSEND` -- a bare `r<d> =
self;`, since `r0` is already wired to `self` at the top of every
generated function); `MUL` (confirmed reading `src/vm.c`: `OP_ADD`/
`OP_SUB`/`OP_MUL` all expand from the identical `OP_MATH` macro, so this
is `ADD`/`SUB`'s own fixnum-fastpath-else-`mrb_funcall` shape exactly,
no new design question); `ARRAY` (a literal array from N consecutive
already-evaluated registers, real `OP_ARRAY` semantics -- only the
plain non-splat literal shape is modeled, `ARRAY2`/`ARYCAT`/`ARYPUSH`/
`ARYSPLAT` left `#error`, matching `LOADL`'s own established narrow-
scope precedent); `AREF` (`R[a] = R[b][c]`, a plain immediate index --
the real shape a destructuring multiple-assignment off one call result
compiles to, e.g. `x, y, w, h = some_call(...)`).

**A real, previously-flagged-but-unfixed bug, finally closed.** Two
follow-ups up, this file's own text named the gap directly: "MONO
devirtualization never checking whether its own target's irep will
actually be emitted... not fixed here -- flagged for whoever next
touches `compile_send`'s own MONO path." Building `Game::Screen`
exercised it for real: `#update`'s own devirtualized calls to
`#update_shake`/`#update_flash` kept referencing their `_impl`
functions directly even while `MUL` (needed by both bodies) was, for a
time, still unsupported -- an undefined-reference link failure, not a
diagnostic nuisance, that the two previously-shipped targets never
happened to trigger. Fixed with `compiles_clean?`: rather than
re-deriving `compile_insn`'s own opcode-support list by hand a second
time (a real drift risk), it memoizes an actual `compile_method(label)`
call and checks the result for a `#error` marker -- the same test
`SKIP_UNSUPPORTED` itself uses -- guarded against recursion (a label
already being probed reports "not yet known clean" rather than looping,
always the safe direction).

**A second, related bug, caught at the same time:** a call site's own
argument count was never checked against its devirtualization target's
real mandatory arity. A bytecode-only registry has no visibility into a
same-named *native* method (`extract_native_method_names`'s own known
gap) -- run this tool without `NATIVE_SRCS` (as this project's own
421-error baseline measurement always has) and `Input.repeat?(key)` (a
real native 1-arg method on an unrelated class) looks MONO next to
`Game::MoveRoute#repeat?` (a real 0-arg getter, the only bytecode-
visible definition of that bare name) -- 120 real call sites devirtualized
straight into a 0-argument function with 1 argument, a real g++ compile
error, not a hypothetical. Real gem builds always pass `NATIVE_SRCS`
(which already flips a true collision like this to POLY), but the
arg-count check added here (`mandatory_arity`, parsing the same `ENTER`
field `pure_mandatory_arity?` already reads) is a strictly cheaper,
always-correct second line of defense needing no `NATIVE_SRCS` input at
all -- applied to both the MONO and the class-exact TYPED
devirtualization paths.

**`Game::Screen` is the first shipped target whose ivars actually embed.**
Unlike `Game::Picture`/`Game::EnemyAction`/`RGSS::Sprite`, `Screen#initialize`
takes zero arguments and compiles clean -- so `drop_unsafe_embeddings`
does *not* refuse here: 21 of Screen's own ivars (all provably Fixnum)
are real struct fields on a new `Game__Screen_ivars` RData payload,
needing a real `MRB_SET_INSTANCE_TT(screen, MRB_TT_DATA)` call before any
`Game::Screen.new` can run -- the same requirement `mruby-rgss/src/lib.cxx`'s
own natively-implemented classes already meet, just needed here for the
first time. The other 14 real ivars (non-Fixnum: two `Game.clamp`-sourced
tint arrays, three booleans this compiler's embedding lattice doesn't
model, one real object reference) stay on the ordinary dynamic `iv_tbl`,
mixed safely with the embedded 21 on the very same object.

**Real synergy from covering two classes together, not separately:**
`Game::Screen`'s own isolated diagnostic (opcode work: `ARRAY` only)
found 36 of 43 methods clean. `RPG2k::Window`'s own isolated diagnostic
(opcode work: `LOADSELF`/`MUL`/`ARRAY`/`AREF`) found 32 of 35. Merging
both opcode sets together before the real build unblocked three *more*
`Game::Screen` methods neither round alone reached: `#restore_tint`
(destructures two array-literal-shaped arguments -- needs `AREF`, which
only `RPG2k::Window`'s own round added), `#update_shake`/`#update_flash`
(each a plain multiplication -- needs `MUL`, same story). Final real
count: **39 of `Game::Screen`'s 43 methods, 32 of `RPG2k::Window`'s 35**.
Screen's remaining 4 (`#load_h`, `#erase`, `#show`, `#pan`) and Window's
remaining 3 (`#initialize`, four optional arguments; `#dispose` and
`#draw_arrow_fallback`, real block/`yield` usage) are genuinely out of
this prototype's scope, not a further opcode gap worth chasing here.

**Verified for real, independently re-measured:** the real, opt-in
`RPGMAKER_BC2CPP=1` build (`rake .../host/lib/libmruby.a`) succeeds end
to end against the actual project sources, and `nm -C` on the resulting
`libmruby.a` shows all 71 new entry points (39 `Game__Screen_*_impl`, 32
`RPG2k__Window_*_impl`) present and externally linked, plus the new
`Game__Screen_ivars_free` helper. Syntax-checking the full, unrestricted
(no `ONLY_OWNERS`) closed-world output with `g++ -fsyntax-only` -- the
same check that found the pre-existing 434→421-error gap the previous
two follow-ups tracked -- now reports **0 errors**: the devirtualization-
soundness fix above closes that entire pre-existing gap, not just this
round's own two new classes. The same run emits **1,922** real `_impl`
method bodies across the whole closed world (up from 1,514). Both
already-shipped compiled targets (`LCF::File`'s subclasses, `Game::Picture`/
`Game::EnemyAction`, `RGSS::Sprite`) remain unaffected.

## Follow-up: Game::Transition, Game::Actor, and the GETIDX/SETIDX/GETGV opcodes

Two more classes, again developed as independent parallel slices and
merged by hand: `Game::Transition` (RPG2000's ~38 screen transition
styles -- fades, block-shuffle wipes, zoom, mosaic, wave, scroll-in/out,
cut, `mruby-rpg2k/mrblib/game.rb`) and `Game::Actor` (real player-character
stats/equipment/leveling/battle state, the same file plus a second
reopening in `mruby-rpg2k/mrblib/game/battle_support.rb`) -- the biggest
real target yet.

**`Game::Transition` needed no new opcode work at all** -- the
`LOADSELF`/`MUL`/`ARRAY`/`AREF` set the previous round added already
covers it fully: 32 of its 38 real methods (including `#initialize`
itself, 5 purely-mandatory arguments) compile clean. It is the *second*
real target with an embedding `#initialize`, after `Game::Screen`: 5
provably-Fixnum ivars (`@style`, `@frames`, `@width`, `@height`, `@frame`)
are real fields on a new `Game__Transition_ivars` RData struct, the one
other real ivar (`@erase`, a boolean) staying on the ordinary `iv_tbl`.
The 6 methods that stay interpreted (`block_rects`, `blind_rects`,
`vertical_stripe_rects`, `horizontal_stripe_rects`, `clip`,
`compute_block_order`) all use a genuine Ruby block (`BLOCK`/`SENDB`),
confirmed against the real generated `#error` lines, not guessed --
matching `RPG2k::Window#dispose`/`#draw_arrow_fallback`'s own established
out-of-scope shape from the previous round.

A real, concrete case where the devirtualization-soundness fix from two
follow-ups up actually earns its keep: `Game::Transition#block_order`'s
own body (`@block_order ||= compute_block_order`) sends a MONO name whose
one real definition is itself one of the 6 that doesn't compile
(`BLOCK`/`SENDB`) -- `compiles_clean?` correctly refuses to devirtualize
that call, so the generated body falls back to ordinary `mrb_funcall`
instead of referencing a `_impl` this run never emits. Confirmed directly
against the real generated output.

**Three new opcodes for `Game::Actor`**: `GETIDX`/`SETIDX` (a computed-
index Array/Hash read/write -- `arr[i]`/`arr[i]=`, via the same real
`mrb_ary_ref`/`mrb_ary_set`/`mrb_hash_get`/`mrb_hash_set` APIs `AREF`/
`HASH` already use, falling back to `mrb_funcall(..., "[]"/"[]="  , ...)`
for anything else) and `GETGV` (a bare global-variable read, `mrb_gv_get`).
75 of `Game::Actor`'s own real methods compile clean -- 66 with the prior
round's opcode set, 9 more directly unlocked by these three. Far more
significant: the same three opcodes unlocked **348 more real method
bodies project-wide**, across roughly 30 other classes never touched by
this round (`RPG2k::Scene::Battle` alone gained 82, `RPG2k::Scene::Map`
62, `Game::Interpreter` 41, `Game::Battle` 15, `Game::Party` 14) --
the same opcode-reuse payoff the prior round's `MUL`/`AREF` work already
showed, now at a larger scale. `Game::Actor#initialize` and 4 other real
methods stay interpreted for the same non-mandatory-arity gap as
`Game::Picture#initialize`; the remaining 34+ hit `BLOCK`/`SENDB` (the
same established out-of-scope shape) or narrower gaps (`RESCUE`/
`RAISEIF`/`EXCEPT`, `RANGE_INC`, `ADDILV`/`SUBILV`/`NOP` for a `while`
loop) genuinely left alone rather than forced. `Game::Actor`'s own
provably-Fixnum ivars stay unembedded, same shape as `Game::Picture`/
`RPG2k::Window` -- `#initialize` itself doesn't compile.

Cross-checked for synergy between `Game::Transition` and `Game::Actor`
themselves the same way the previous round found three extra
`Game::Screen` methods from combining opcode sets: re-running both
classes' own diagnostics against the fully merged `bc2cpp.rb` found no
additional methods unlocked between the two (`32`/`75` exactly, matching
each round's own isolated count). But a *wider* sweep -- re-checking
every already-shipped target, not just this round's own two new classes,
against the final merged `bc2cpp.rb` -- caught what that narrower check
missed: `GETIDX` also unblocks two real `Game::Screen` methods from the
*previous* round, `#load_h` (`h[:pan_x]`, a Hash `#[]` read) and `#pan`
(`PAN_DELTA[direction]`, same shape) -- both flagged at the time as
blocked by exactly this gap, closed by an opcode a *different* round
added for a *different* class entirely. `Game::Screen` is now at **41**
of its own 43 real methods, not 39. The lesson generalizes: checking
synergy only between a round's own new targets isn't enough -- every
opcode addition needs a full sweep across every already-shipped target
before the round is considered done.

**Verified for real, independently re-measured:** the real, opt-in
`RPGMAKER_BC2CPP=1` build succeeds end to end, and `nm -C` on the
resulting `libmruby.a` shows all 109 new entry points (32
`Game__Transition_*_impl`, 75 `Game__Actor_*_impl`, and the 2 newly-
unblocked `Game::Screen` methods above) present and externally linked,
plus the new `Game__Transition_ivars_free` helper. The full, unrestricted
closed-world `g++ -fsyntax-only` check still reports **0 errors**
(unchanged from the previous round). The same run now emits **2,618**
real `_impl` method bodies across the whole closed world (up from
1,922) -- a 696-body jump, mostly from `GETIDX`/`SETIDX`/`GETGV`
unlocking methods project-wide rather than from these two classes alone.
Every already-shipped target except `Game::Screen` (the 2-method gain
above) is otherwise unaffected: `LCF::File`'s subclasses,
`Game::Picture`/`Game::EnemyAction`, `RGSS::Sprite`, and `RPG2k::Window`
all remain exactly as they were.

## Follow-up: Game::Party, RPG2k::Scene::MapViewer, and a live bug in already-shipped Game::Actor

Two more classes, again developed as independent parallel slices: `Game::Party`
(party-wide item/skill usability rules, equip/swap logic, skill damage
formulas, state/status application, battle placement,
`mruby-rpg2k/mrblib/game.rb` plus a second reopening in `game/
battle_support.rb`) and `RPG2k::Scene::MapViewer` (the F9 debug-menu map
overview/editor scene -- pan/zoom camera, a tile-selection cursor, a
select/edit mode toggle, header/footer HUD text,
`mruby-rpg2k/mrblib/scene/map_viewer.rb`).

**`Game::Party` needed six new opcodes**, all narrow mechanical
translations of their own real VM semantics: `NOP` (a real, literal
"do nothing," a `while` loop's own condition-check jump target);
`ADDILV`/`SUBILV` (a `while` loop's own `i += 1`/`i -= 1` local-variable
increment/decrement -- the same fixnum-fastpath-else-`mrb_funcall` shape
`ADDI`/`SUBI` already have, needing its own real trailing-comment-extraction
fix distinct from `ADDI`'s, since an `*LV` register is *always* a named
local by definition, not a rare case); `RANGE_INC`/`RANGE_EXC` (an
inclusive/exclusive Range literal, `mrb_range_new`); and `RETURN_BLK`
(looks block-specific by name, but its own real VM semantics fall through
to a plain `RETURN` whenever the executing proc is `MRB_PROC_STRICT_P` --
true for every real `def`-compiled method this compiler ever sees, never
a genuine block/proc irep, confirmed reading `OP_METHOD`'s own lambda-
creation path). 85 of `Game::Party`'s own 128 real methods compile clean.

**`RPG2k::Scene::MapViewer` needed one new opcode**: `GETIDX0`, mrbc's own
peephole for a literal `x[0]` index (a separate instruction from `GETIDX`,
since the common case skips carrying an explicit index register at all).
34 of its own 42 real methods compile clean.

**A real, live memory-safety bug, found by this round's own full-sweep
discipline and fixed immediately.** The established practice from two
follow-ups up -- checking every already-shipped target against the final
merged opcode set, not just a round's own new classes -- caught something
worse than a missed method this time: `drop_unsafe_embeddings` (the guard
deciding whether a class's ivars get embedded into a real RData struct)
checked only `pure_mandatory_arity?` on `#initialize`, never whether that
`#initialize` actually *finishes compiling*. `Game::Actor#initialize` has
pure mandatory arity (2 required arguments) but still ends in a real
`@equipment.each { ... }` block (`BLOCK`/`SENDB`) -- it was never going to
compile either way, but the old guard didn't check that, and let 7 real
Fixnum ivars (`@id`, `@exp`, `@level`, `@class_id`, `@faceset_index`,
`@face_index`, `@battler_animation_override`) through as "embeddable"
anyway. The result, confirmed live in the actual already-merged build:
16 real, already-shipped `Game::Actor` methods (`faceset_index`,
`set_faceset`, `restore_class`, `gain_exp`, `exp_to_next`, and 11 more)
were generated with `DATA_PTR(self)` struct-field access, but
`register.cxx` never calls `MRB_SET_INSTANCE_TT(actor, MRB_TT_DATA)` --
every real `Game::Actor.new` stays a plain `MRB_TT_OBJECT`, so those 16
methods dereferenced an `RData` payload that was never allocated: real
undefined behavior, on every real `Game::Actor` instance, every time one
of them ran, in code that had already shipped to `master`. Fixed at the
root: `drop_unsafe_embeddings` now also requires `compiles_clean?` on
`#initialize` -- the same real `#error`-marker check `compile_send`'s own
MONO-devirtualization fix already uses, applied to the embedding gate
instead. Confirmed by direct re-inspection of the regenerated output:
`Game::Actor` no longer appears in bc2cpp's own "classes needing
`MRB_SET_INSTANCE_TT`" diagnostic, no `DATA_PTR(self)` access remains
anywhere in its own compiled methods, and all 76 of its registered entry
points are otherwise completely unaffected (identical arity, visibility,
and symbol names) -- only the unsafe struct-field access underneath a
handful of them changed back to the ordinary, always-safe dynamic
`iv_tbl`.

**Full-sweep synergy, both directions.** `SUBILV`, added for
`Game::Party`, also unblocks `Game::Actor#set_exp` (`new_level -= 1
while ...`) -- Game::Actor is now 76 of its own methods, not 75, even
though this round's own source changes never touched it. `GETIDX0`,
added for `RPG2k::Scene::MapViewer`, also unblocks 5 more methods across
`Game::Battle`/`Game::MoveRoute`/`RPG2k::Scene::{Battle,Map}` -- none of
them in any already-shipped compiled target's own owner set yet, so no
further registration needed this round, just a real, confirmed fact
banked for whichever future round targets those classes. A full sweep of
every one of the eight now-shipped targets against the final merged
opcode set found nothing else moved: `Game::Picture` (25),
`Game::EnemyAction` (6), `Game::Screen` (41), `RPG2k::Window` (32),
`Game::Transition` (32), `Game::Actor` (76), `Game::Party` (85),
`RPG2k::Scene::MapViewer` (34) -- all exactly matching each round's own
independently-verified count.

**Verified for real, independently re-measured:** the real, opt-in
`RPGMAKER_BC2CPP=1` build succeeds end to end, and `nm -C` on the
resulting `libmruby.a` shows all 119 new entry points (85
`Game__Party_*_impl`, 34 `RPG2k__Scene__MapViewer_*_impl`) present and
externally linked, plus `Game__Actor_set_exp_impl` and the confirmed
absence of `Game__Actor_ivars` anywhere in the build (the embedding-bug
fix, directly verified). The full, unrestricted closed-world
`g++ -fsyntax-only` check still reports **0 errors**. The same run now
emits **2,708** real `_impl` method bodies across the whole closed world
(up from 2,618).

## Follow-up: Game::Battle and RPG2k::Scene::ItemMenu, no new opcodes needed

A sixth, parallel round -- two independent background agents, each
starting from its own worktree, then integrated by hand -- adds
`Game::Battle` and `RPG2k::Scene::ItemMenu`, both getting real coverage
for the first time **without needing a single new opcode**: every gap
either class hits was already-known-shape (non-mandatory `#initialize`
arguments, a genuine Ruby block, or a `super` call), and the opcode set
landed for `Game::Party`/`RPG2k::Scene::MapViewer` the round before
already covered everything else, including the one near-opcode-miss
below.

**`Game::Battle`** (`mruby-rpg2k/mrblib/game/battle.rb`) is the headless
turn-based/gauge combat-resolution engine: turn order, command
resolution, hit/damage/state-infliction formulas, enemy AI action
selection. 75 of its own 141 real bytecode-defined methods compile
clean. The other 66 split cleanly into the two already-established
out-of-scope shapes: 15 (including `#initialize` itself, a mix of
optional positional and keyword arguments) fail on non-mandatory arity,
and 51 hit a genuine Ruby block (`BLOCK`/`SENDB`/`SSENDB`). One near-miss
was checked, not assumed: `#apply_knockout_reset`
(`%i[atk_mod def_mod spi_mod agi_mod].each do |field| ... end`) would
also need a dynamic-`SYMBOL` opcode this compiler has never modeled --
but it still ends in that same `.each` block regardless, so adding
`SYMBOL` support alone would not have unlocked it; genuinely not worth
chasing, left interpreted. `#initialize` never compiles, so `Game::Battle`'s
two provably-Fixnum ivars (`@battle_type`, `@rounds`) stay unembedded,
same shape as every other non-embedding target above. Visibility needed
its own real check: a single bare `private` (`battle.rb` line 1720) makes
everything from `#do_nothing_restricted?` on private by default, but
three names are retroactively reopened `public` right after their own
`def` -- of those three, only `#inflict_state`/`#cure_state` actually
compile (the other two, and `#apply_knockout_reset`, all hit the same
block gap), so they alone are registered with plain `mrb_define_method`
despite sitting after the `private` line, the same real visibility-
tracking fix this ADR's own `Game::Picture` `#step`/`#finish_move` bug
already established the need for.

**`RPG2k::Scene::ItemMenu`** (`mruby-rpg2k/mrblib/scene/item_menu.rb`) is
the field/battle item-use menu: item list scrolling/selection, target
selection (including teleport-item map picking), applying item effects.
41 of its own 47 real methods compile clean. `#initialize` itself hits a
real `super parent` call (`SUPER`, out of this compiler's opcode scope,
never added -- no target so far has needed it), and 5 other private
methods use a genuine Ruby block; one more,
`#load_face_bitmap`, has a real `rescue StandardError` clause
(`RETURN_BLK`/`EXCEPT`/`RESCUE`/`RAISEIF`, also out of scope). Because
`#initialize` never compiles, its own provably-Fixnum/Symbol ivars
(`@mode`/`@item_index`/`@item_top`/`@target_index`/`@teleport_index`/
`@arrow_anim`) stay unembedded too.

**Independent duplicate work, reconciled by hand.** Both background
agents' worktrees were branched before the prior (`Game::Party`/
`RPG2k::Scene::MapViewer`) round had merged, so each independently
re-derived and re-applied that round's own `drop_unsafe_embeddings`
`compiles_clean?` fix and `RANGE_INC`/`RANGE_EXC` opcode against its own
stale base -- real, correct fixes, just already shipped on `master` by
the time both agents reported back. Integrating by hand meant diffing
each agent's own commit against its *real* parent (not `master`) to
isolate what was actually new, applying only `Game::Battle`'s and
`RPG2k::Scene::ItemMenu`'s own registration blocks (`register.cxx`) and
owner-list entries (`compiled_gems.rb`) on top of the already-merged
`master`, and discarding both agents' redundant `bc2cpp.rb` diffs
entirely -- `master`'s own shipped fix and opcode implementation were
kept unchanged rather than replaced with either agent's independently-
reasoned (differently-worded, equally-correct) reimplementation, to avoid
churn risk on code that had already passed three rounds of real
verification.

**Full-sweep re-check, as always.** Since this round added no new
opcodes, no already-shipped target could gain anything, and a fresh
unrestricted diagnostic confirmed exactly that: all ten now-shipped
targets' own entry-point counts -- `Game::Picture` (25),
`Game::EnemyAction` (6), `Game::Screen` (41), `RPG2k::Window` (32),
`Game::Transition` (32), `Game::Actor` (76), `Game::Party` (85),
`RPG2k::Scene::MapViewer` (34), `Game::Battle` (75),
`RPG2k::Scene::ItemMenu` (41) -- match exactly what each round's own
independent verification already found; nothing moved.

**Verified for real:** the real, opt-in `RPGMAKER_BC2CPP=1` build
succeeds end to end (`EXIT: 0`), and `nm -C` on the resulting
`libmruby.a` shows all 116 new entry points (75 `Game__Battle_*_impl`,
41 `RPG2k__Scene__ItemMenu_*_impl`) present and externally linked, with
every one of the eight already-shipped classes' own symbol counts
unchanged. The full, unrestricted closed-world `g++ -fsyntax-only` check
still reports **0 errors**.

## Follow-up: RPG2k::Scene::SkillMenu, RPG2k::Scene::DebugMenu, and a stale-cache build bug found integrating them

A seventh, parallel round -- again two independent background agents,
integrated by hand -- adds `RPG2k::Scene::SkillMenu` and
`RPG2k::Scene::DebugMenu`, two more `RPG2k::Scene::MapViewer` siblings.
Neither needed any new opcode work: the six rounds of opcode coverage
already built up cover every real shape both classes' own method bodies
use.

**`RPG2k::Scene::SkillMenu`** (`mruby-rpg2k/mrblib/scene/skill_menu.rb`)
is the field/battle skill-use menu (skill list scrolling/selection,
target selection including the teleport-skill map picker, applying a
chosen skill's effect). 39 of its own 46 real methods compile clean.
`#initialize` (`actor_index = 0`, one optional argument) stays
interpreted, the same non-mandatory-arity gap as `Game::Picture`'s/
`RPG2k::Window`'s/`Game::Actor`'s/`Game::Party`'s/
`RPG2k::Scene::MapViewer`'s own `#initialize`. The other 6 gaps are two
`rescue` clauses (`#load_face_bitmap`, `#play_skill_sound_effect`) and
four genuine Ruby blocks (`#draw_skill_rows`, `#build_target_window`,
`#teleport_targets`, `#build_teleport_window`).

**`RPG2k::Scene::DebugMenu`** (`mruby-rpg2k/mrblib/scene/debug_menu.rb`)
is the F9 debug menu itself: Switch/Variable block-and-row editing plus
the Map/Chipset/Animation tool pages. 33 of its own 39 real methods
compile clean. **First shipped target whose `#initialize` is blocked by
a real `super` call** (`super parent`, `OP_SUPER`) rather than
non-mandatory arity, a Ruby block, or an exception clause -- a genuine
class-hierarchy method-dispatch feature (resolving and invoking
`RPG2k::Scene::Base#initialize`, not just `self`'s own method table),
judged out of this prototype's "narrow mechanical translation" scope
rather than added speculatively for the one method it would unlock here.
The other 5 gaps: `#max_id`/`#refresh_switch_or_variable` (two Ruby
blocks each), `#digits_of` (one), `#editor_value` (one), and
`#open_map_viewer` -- which actually has *two* independent gaps, one per
branch of its own `if`/`else`, a `rescue StandardError` clause plus an
unrelated keyword-argument call site; see this ADR's own later follow-up
for the full correction to this comment. Neither class's `#initialize`
compiles, so neither gets any ivar embedded.

**A real build-system bug, found integrating this round, not either
agent's own work.** Both `RPG2k::Scene::SkillMenu` and
`RPG2k::Scene::DebugMenu` compiled and linked cleanly inside each
agent's own fresh worktree -- but integrating both into this same
already-built tree (the same directory a prior round's real build had
already run in) failed with `g++` reporting the new classes'
`_impl` functions "not declared in this scope". Root cause: each
compiled gem's own `mrbgem.rake` declares its generated whole-program
C++ file (`rpg2k_compiled_gen.cpp` and its two siblings) as a Rake `file`
target depending on `bc2cpp.rb` and the closed-world `.rb` sources --
but never on `tools/bc2cpp/compiled_gems.rb`, the file that actually
defines which classes get emitted (`BC2CPP_COMPILED_GEMS[...][:owners]`).
Editing only `compiled_gems.rb`'s own owners list -- exactly what
integrating a new round's coverage always does -- left Rake believing
the already-built generated file was still up to date, so it kept
serving the prior round's stale content while `register.cxx`'s own
hand-written call sites for the new classes' methods had nothing to
link against. Not a new bug in this round's compiled code, and not
something either background agent could have hit (each built in its own
fresh worktree with no stale generated file to begin with) -- purely a
gap in the integration step's own incremental-build assumptions,
invisible until a second round landed on top of a first. Fixed at the
root in all three `mrbgem.rake` files (`mruby-rpg2k-compiled`,
`mruby-lcf-compiled`, `mruby-rgss-compiled`, which all share this exact
pattern): added `compiled_gems.rb`'s own path as an explicit prerequisite
of the `generated` file rule. Verified for real, not just reasoned
about: touched `compiled_gems.rb` with no content change, reran the
build, and confirmed the generated file's own mtime advanced and the
build still succeeded -- proving Rake now treats it as a real dependency
rather than trusting this fix by inspection alone.

**Full-sweep re-check.** Since this round added no new opcodes, no
already-shipped target could gain anything, and a fresh unrestricted
diagnostic confirmed exactly that: all twelve now-shipped targets' own
entry-point counts -- `Game::Picture` (25), `Game::EnemyAction` (6),
`Game::Screen` (41), `RPG2k::Window` (32), `Game::Transition` (32),
`Game::Actor` (76), `Game::Party` (85), `RPG2k::Scene::MapViewer` (34),
`Game::Battle` (75), `RPG2k::Scene::ItemMenu` (41),
`RPG2k::Scene::SkillMenu` (39), `RPG2k::Scene::DebugMenu` (33) -- match
exactly; nothing moved.

**Verified for real, after fixing the stale-cache bug above:** the real,
opt-in `RPGMAKER_BC2CPP=1` build succeeds end to end (`EXIT: 0`), and
`nm -C` on the resulting `libmruby.a` shows all 72 new entry points (39
`RPG2k__Scene__SkillMenu_*_impl`, 33 `RPG2k__Scene__DebugMenu_*_impl`)
present and externally linked, with every one of the ten already-shipped
classes' own symbol counts unchanged. The full, unrestricted
closed-world `g++ -std=c++17 -fsyntax-only` check still reports **0
errors**.

## Follow-up: RPG2k::Scene::EquipMenu, RPG2k::Scene::Menu, and a real LAMBDA-shaped near-miss

An eighth, parallel round -- again two independent background agents,
integrated by hand -- adds `RPG2k::Scene::EquipMenu` and
`RPG2k::Scene::Menu`, two more `RPG2k::Scene` siblings. Neither needed
any new opcode work.

**`RPG2k::Scene::EquipMenu`** (`mruby-rpg2k/mrblib/scene/equip_menu.rb`)
is the field equip screen: weapon/armor/accessory slot selection, a
two-column bag-item candidate grid, per-stat before/after deltas. 29 of
its own 36 real methods compile clean. `#initialize` (`actor_index = 0`,
one non-mandatory argument) stays interpreted, the same established gap
as every other non-embedding target above; the other 6 gaps
(`#draw_stat_row`/`#build_slot_window`/`#build_cand_window`'s own
`each_with_index`, `#item_stat_sum`/`#equip_delta`'s own `reduce`,
`#draw_arrow_fallback`'s own `ARROW_H.times`) are all a genuine Ruby
block.

**`RPG2k::Scene::Menu`** (`mruby-rpg2k/mrblib/scene/menu.rb`) is the
field main menu: the top-level party navigation hub covering
Item/Skill/Equip/Status/Save/Quit, the party-status panel, the end-game
confirmation dialog, and the gold display. 28 of its own 35 real methods
compile clean. `#initialize` (a real `super parent` call, `SUPER`) and
`#load_face_bitmap` (a real `rescue StandardError` clause) match
`RPG2k::Scene::ItemMenu`'s own pair of gaps exactly -- both classes even
share the `#load_face_bitmap` method name (POLY at every real call site,
never MONO). Four more methods
(`#build_commands`/`#build_windows`/`#draw_command_labels`/
`#build_end_game_confirm_windows`) end in a genuine Ruby block.

**One real near-miss, checked rather than chased**:
`#draw_status_row`'s own `line = ->(n) { y + n * LINE_H }` hits a
**`LAMBDA`** opcode no earlier round had ever seen. Investigated instead
of assumed: a lambda literal creates a real closure over the enclosing
scope's own local (`y`) the same way `BLOCK`/`SENDB` do for a `do...end`
block -- just different call-site syntax (`OP_LAMBDA` vs `OP_BLOCK` both
create a `RProc` from a child `mrb_irep` capturing the enclosing
`upper`). Judged the same permanently-out-of-scope closure-creation gap,
not a narrow single-opcode mechanical translation, so left interpreted
rather than adding `LAMBDA` support for the one method it would unlock
here. Neither `RPG2k::Scene::EquipMenu`'s nor `RPG2k::Scene::Menu`'s own
`#initialize` compiles, so neither gets any ivar embedded.

**Full-sweep re-check.** Since this round added no new opcodes, no
already-shipped target could gain anything, and a fresh unrestricted
diagnostic confirmed exactly that: all fourteen now-shipped targets' own
entry-point counts -- `Game::Picture` (25), `Game::EnemyAction` (6),
`Game::Screen` (41), `RPG2k::Window` (32), `Game::Transition` (32),
`Game::Actor` (76), `Game::Party` (85), `RPG2k::Scene::MapViewer` (34),
`Game::Battle` (75), `RPG2k::Scene::ItemMenu` (41),
`RPG2k::Scene::SkillMenu` (39), `RPG2k::Scene::DebugMenu` (33),
`RPG2k::Scene::EquipMenu` (29), `RPG2k::Scene::Menu` (28) -- match
exactly; nothing moved.

**Verified for real:** the real, opt-in `RPGMAKER_BC2CPP=1` build
succeeds end to end (`EXIT: 0`) -- the first round since the prior
follow-up's own stale-cache fix to reuse an already-built tree, and it
succeeded on the first try, confirming that fix holds. `nm -C` on the
resulting `libmruby.a` shows all 57 new entry points (29
`RPG2k__Scene__EquipMenu_*_impl`, 28 `RPG2k__Scene__Menu_*_impl`)
present and externally linked, with every one of the twelve
already-shipped classes' own symbol counts unchanged. The full,
unrestricted closed-world `g++ -std=c++17 -fsyntax-only` check still
reports **0 errors**.

## Follow-up: Game::State's own real RData embedding, RPG2k::Scene::StatusMenu, and a checked non-bug

A ninth, parallel round -- again two independent background agents,
integrated by hand -- adds `Game::State` and `RPG2k::Scene::StatusMenu`.
Neither needed any new opcode work.

**`Game::State`** (`mruby-rpg2k/mrblib/game.rb`, reopened by
`mruby-rpg2k/mrblib/game/lsd_io.rb`) is the whole-program root save/
session object: party, switches, variables, map position, pictures,
both timers, the message window config, screen-transition defaults,
vehicle placement, and the Marshal/`.lsd` (de)serialisers. 23 of its own
32 real bytecode-defined methods compile clean. The other 9 split
cleanly into the two already-established out-of-scope shapes: 3
non-mandatory arity (`#move_picture`'s own splat, `#tick_timer`/
`#timer`'s own optional argument, `#to_lsd`'s own 5 all-optional
arguments), 4 genuine Ruby blocks (`#update_pictures`/`#pictures_moving?`'s
own `&:update`/`&:moving?` block-pass shorthand, `#to_h`'s own two), and
2 that combine a block with a real `rescue StandardError` clause
(`#seed_screen_transitions`, `#seed_vehicle_positions`).

**`#initialize` compiles clean** (4 purely mandatory arguments, no
opts) -- the third target, after `Game::Screen`/`Game::Transition`
above, whose own `#initialize` compiles, and by far the largest: 13 of
its own ivars (`@map_id`, `@x`, `@y`, `@direction`,
`@encounter_total`, `@steps`, `@save_count`, `@battle_count`,
`@win_count`, `@defeat_count`, `@escape_count`, `@font_id`, `@atb_mode`
-- all provably Fixnum) get real `RData` struct embedding via
`MRB_SET_INSTANCE_TT(state, MRB_TT_DATA)`, mixed safely on the same
object with every other real (non-Fixnum) ivar -- `@party`, `@switches`,
`@pictures`, `@screen`, and more -- staying on the ordinary dynamic
`iv_tbl`, the same mixed-embedding shape `Game::Screen`'s/
`Game::Transition`'s own non-Fixnum ivars already established.

**Checked directly against the exact `Game::Actor`-shaped bug two
follow-ups up**, not assumed safe by analogy: that earlier bug happened
because a class's own ivars got embedded even though `#initialize`
itself never actually ran (blocked by a `BLOCK`/`SENDB` gap), so no real
instance ever got `mrb_data_init`'d. Here `#initialize` genuinely
compiles and always runs on every real construction path --
`Game::State.load` (the interpreted class method that rebuilds a
`Game::State` from a loaded save) never bypasses it, constructing every
real instance via a plain `new(party, map_id, x, y)` call before setting
any other field. `mrb_data_init` always runs before an embedded field is
ever touched, on both the "new game" and "load game" paths -- confirmed
by reading `Game::State.load`'s own real source, not by re-deriving the
safety argument from first principles alone.

**`RPG2k::Scene::StatusMenu`** (`mruby-rpg2k/mrblib/scene/status_menu.rb`)
is the field per-character status detail screen: stats, equipped gear,
and EXP progress for one selected party member, drawn across five
windows. 13 of its own 21 real methods compile clean. `#initialize`
(`actor_index = 0`, one non-mandatory argument, plus a `super parent`
call) stays interpreted, the same established gap as every other
non-embedding target above, so its own one real ivar (`@actor_index`)
stays unembedded too. The other 7 gaps: `#update`/`#dispose` (each a
real `windows.each { |w| ... }` block), `#draw_actor_panel`/
`#draw_params`/`#draw_equipment` (each a real `.each_with_index do
|...| ... end` block), `#draw_value_row` (one non-mandatory argument,
`can_knockout = nil`), and `#load_face_bitmap` (a real `rescue
StandardError` clause, the same shape `RPG2k::Scene::SkillMenu`'s own
same-named method already has).

**Full-sweep re-check.** Since this round added no new opcodes, no
already-shipped target could gain anything, and a fresh unrestricted
diagnostic confirmed exactly that: all sixteen now-shipped targets' own
entry-point counts -- `Game::Picture` (25), `Game::EnemyAction` (6),
`Game::Screen` (41), `RPG2k::Window` (32), `Game::Transition` (32),
`Game::Actor` (76), `Game::Party` (85), `RPG2k::Scene::MapViewer` (34),
`Game::Battle` (75), `RPG2k::Scene::ItemMenu` (41),
`RPG2k::Scene::SkillMenu` (39), `RPG2k::Scene::DebugMenu` (33),
`RPG2k::Scene::EquipMenu` (29), `RPG2k::Scene::Menu` (28), `Game::State`
(23), `RPG2k::Scene::StatusMenu` (13) -- match exactly; nothing moved.
The whole-program embedding diagnostic confirms `Game::State` now
correctly appears in the "classes needing `MRB_SET_INSTANCE_TT`" list
alongside the already-shipped `Game::Screen`/`Game::Transition`.

**Verified for real:** the real, opt-in `RPGMAKER_BC2CPP=1` build
succeeds end to end (`EXIT: 0`; the main checkout's own `3rd/effekseer`
submodule needed a one-time `git submodule update --init --recursive`
first -- an unrelated environment gap, not caused by this round's own
diff). `nm -C` on the resulting `libmruby.a` shows all 36 new entry
points (23 `Game__State_*_impl`, 13 `RPG2k__Scene__StatusMenu_*_impl`)
present and externally linked, plus the new `Game__State_ivars`
struct/type-descriptor pair confirming the real embedding took effect,
with every one of the fourteen already-shipped classes' own symbol
counts unchanged. The full, unrestricted closed-world
`g++ -std=c++17 -fsyntax-only` check still reports **0 errors**.

## Follow-up: Game::MoveRoute, RPG2k::Scene::ChipsetEditor, and a real MRB_SYM_Q/B/E native-name blind spot

A tenth, parallel round -- again two independent background agents,
integrated by hand -- adds `Game::MoveRoute` and
`RPG2k::Scene::ChipsetEditor`. Neither needed any new opcode work, but
this round's own full-sweep discipline caught a real, live correctness
bug in `bc2cpp.rb` itself.

**`Game::MoveRoute`** (`mruby-rpg2k/mrblib/game.rb`) is the RPG2000 "Set
Move Route" event-command engine: a character's programmed queue of
move/turn/wait/jump/effect sub-commands, with the repeat/skip-if-blocked
flags a route carries. 18 of its own 19 real bytecode-defined methods
compile clean. `#initialize` (`commands, repeat: true, skippable:
false`) hits the same non-mandatory-arguments gap as every other
unembedded target above, this time via real keyword arguments. Two more
real methods, `.from_page` and `.same_route?`, turned out to be
singleton (`def self.`) methods -- invisible to `bc2cpp`'s own
`build_registry` for a structural reason, not an opcode gap: its own
`CLASS`/`MODULE`/`TDEF` walk never recognizes an `SCLASS`-opened body,
so a `def self.foo` method's own `TDEF` is never reached by the walk at
all. This is an existing, program-wide gap (no compiled gem anywhere in
this project has ever registered a singleton method) -- `Game::MoveRoute`
is just the first class whose own singleton methods carry real logic
worth naming here.

**`RPG2k::Scene::ChipsetEditor`** (`mruby-rpg2k/mrblib/scene/
chipset_editor.rb`) is the F9 debug menu's Chipset page: a Lower/Upper
tile-passability grid editor. 17 of its own 20 real methods compile
clean. `#initialize` (a `quit_on_close:` keyword argument plus a real
`super parent` call) matches `RPG2k::Scene::ItemMenu`'s/`DebugMenu`'s/
`Menu`'s own `SUPER` gap, just paired with non-mandatory arity too;
`#save_to_disk` has a real `rescue StandardError` clause; `#draw_grid`
ends in a genuine Ruby block.

**A real, live correctness bug, found by this round's own full-sweep
discipline, not either background agent's own new-class work.**
`extract_native_method_names` -- the whole-program scanner that makes
mruby's own *native* (C-implemented) methods visible to `bc2cpp`'s
MONO/POLY devirtualization registry, so a compiled call site never
wrongly assumes a name belongs only to a bytecode-defined method --
recognized `MRB_SYM(name)`/`MRB_OPSYM(op)` but not three real, distinct
sibling macros `3rd/mruby/include/mruby/presym.h` also defines:
`MRB_SYM_Q(name)` -> `"name?"`, `MRB_SYM_B(name)` -> `"name!"`,
`MRB_SYM_E(name)` -> `"name="`. mruby core reaches for these constantly
-- `Array#empty?`, `Kernel#nil?`/`#frozen?`/`#respond_to?`,
`Numeric#zero?`/`#even?`/`#odd?`, `Hash#key?`/`#has_key?`,
`Range#cover?`, `String#chomp!`/`#downcase!`, `IO#sync=`, and more --
so every one of those names was invisible to the registry, exactly the
"whole-program" premise the registry itself exists to guarantee.

Surfaced concretely, not hypothetically: `array.c`'s own ROM method
table spells `Array#empty?` as `MRB_MT_ENTRY(mrb_ary_empty_p,
MRB_SYM_Q(empty), ...)`, which the old regex simply never matched, so
the registry saw only `Game::MoveRoute#empty?`'s own bytecode
definition for the name `:empty?` and reported it MONO.
`compile_send` then devirtualized `@commands.empty?` (a plain `Array`)
straight into `Game__MoveRoute_empty__impl` calling itself -- real
infinite recursion, caught only because g++'s own
`-Winfinite-recursion` happened to flag a literal self-call. The exact
same collision against any *other* class's own same-named native method
(`#nil?`, `#zero?`, `#key?`, ...) would have compiled clean and silently
misresolved instead, invisible to any compiler warning -- a materially
worse failure mode than a crash, since it would have run wrong, not
failed loudly.

Fixed at the root in `bc2cpp.rb` itself: `extract_native_method_names`'s
own regex now matches all five macros
(`MRB_(SYM_Q|SYM_B|SYM_E|SYM|OPSYM)\((\w+)\)`, the longer alternatives
ordered before the bare `SYM` one) and resolves each to its real Ruby
method name (`"#{name}?"`/`"#{name}!"`/`"#{name}="`/the `OPSYM_TO_RUBY`
table/the bare name). Confirmed by diff that every one of the sixteen
previously-shipped classes' own generated C++ is byte-for-byte
unchanged by the fix -- no live corruption existed in already-shipped
code, this bug just hadn't been triggered by a same-named
native/compiled collision yet, purely because no earlier target
happened to define a method sharing a name with an `MRB_SYM_Q`/`_B`/`_E`
native one.

**A related methodology gap, found integrating this round.** Every
prior follow-up's own "full unrestricted closed-world diagnostic" (run
by hand, directly invoking `bc2cpp.rb` for a post-merge full-sweep
re-check) never set `NATIVE_SRCS`, unlike every real gem's own
`mrbgem.rake` invocation -- so it never had visibility into native
methods at all, the exact blind spot this round's own bug lived in.
Re-running this round's own full-sweep diagnostic with `NATIVE_SRCS` set
the same way `mrbgem.rake` computes it (`mruby-rgss/src/*.cxx` plus
`core_native_srcs`) reproduces the `Game::MoveRoute#empty?` self-call
directly in the generated text when run against the *pre-fix* source,
and confirms it now correctly compiles to a real `mrb_funcall`-based
POLY dispatch post-fix -- direct textual confirmation, not just an
absent warning. Every future round's own full-sweep diagnostic should
set `NATIVE_SRCS` the same way from now on.

**Full-sweep re-check** (this time with `NATIVE_SRCS` correctly set):
all eighteen now-shipped targets' own entry-point counts --
`Game::Picture` (25), `Game::EnemyAction` (6), `Game::Screen` (41),
`RPG2k::Window` (32), `Game::Transition` (32), `Game::Actor` (76),
`Game::Party` (85), `RPG2k::Scene::MapViewer` (34), `Game::Battle` (75),
`RPG2k::Scene::ItemMenu` (41), `RPG2k::Scene::SkillMenu` (39),
`RPG2k::Scene::DebugMenu` (33), `RPG2k::Scene::EquipMenu` (29),
`RPG2k::Scene::Menu` (28), `Game::State` (23),
`RPG2k::Scene::StatusMenu` (13), `Game::MoveRoute` (18),
`RPG2k::Scene::ChipsetEditor` (17) -- match exactly; nothing moved.

**Verified for real:** the real, opt-in `RPGMAKER_BC2CPP=1` build
succeeds end to end (`EXIT: 0`), and the full build log shows **zero**
`-Winfinite-recursion` warnings anywhere. `nm -C` on the resulting
`libmruby.a` shows all 35 new entry points (18
`Game__MoveRoute_*_impl`, 17 `RPG2k::Scene::ChipsetEditor_*_impl`)
present and externally linked, with every one of the sixteen
already-shipped classes' own symbol counts unchanged. The full,
unrestricted, `NATIVE_SRCS`-aware closed-world `g++ -std=c++17
-fsyntax-only` check reports **0 errors**.

## Follow-up: RPG2k::Scene::Base, Game::Character, and a real IvarLayout.join embedding bug

Two more independent classes, plus a second real, live bug found by this
round's own full-sweep discipline -- this time in the embedding
analysis itself, not the devirtualization registry.

**RPG2k::Scene::Base** (`mruby-rpg2k/mrblib/scene/base.rb`, reopened by
`mruby-rpg2k/mrblib/scene/battle_support.rb`) is the common superclass
every other `RPG2k::Scene::*` class in this codebase inherits from --
windowskin loading, the field-menu backdrop, scrolling-list arrow/blink
helpers, system-text/state-colour drawing, system-SFX playback, and
UTF-8-vs-byte string walking. 17 of its own 29 real bytecode-defined
methods compile clean, needing no new opcode work at all -- the opcode
set nine rounds of this ADR had already built up already covered every
real shape this class's own method bodies use. `#initialize` compiles
clean too (pure mandatory arity, and -- being the root of the
`RPG2k::Scene` hierarchy -- no `super` call to block it, unlike every
subclass built on top of it), but its own 3 ivars (`@parent`, `@db`,
`@map_tree`) are all opaque object references, never provably `Fixnum`
on any real construction site, so `bc2cpp`'s own whole-program embedding
diagnostic does not propose `MRB_SET_INSTANCE_TT` for it at all. The 12
methods that stay interpreted are genuinely out of this prototype's
scope, not a missing opcode: `#make_windowskin`, `#play_system_se`,
`#screen_width`, and `#screen_height` each have a real `rescue` clause;
`#build_list_arrow_sprite`, `#draw_system_text`, and `#draw_actor_state`
each have a non-mandatory (trailing default) argument;
`#draw_list_arrow_fallback`, `#clip_text_to_width`,
`#wrap_text_to_width`, and `#draw_wrapped_hint` each call a real Ruby
block; and `#play_animation_se` combines a block with its own `rescue
StandardError` clause.

**A concrete lead for a future round:** `RPG2k::Scene::Base#initialize`
now compiling clean means `RPG2k::Scene::ItemMenu`, `RPG2k::Scene::
DebugMenu`, and `RPG2k::Scene::Menu` -- three classes already shipped in
earlier rounds -- are each blocked from their own `#initialize`
compiling purely by their own `super parent` call into `Base`, not by
anything in their own method bodies. A `SUPER` opcode (discussed, not
yet implemented) would unlock all three at once. Out of scope for this
round: doing it correctly needs whole-program coordination across every
already-shipped scene class's own registration block, not a local
change to one class.

**Game::Character** (`mruby-rpg2k/mrblib/game.rb`) is the shared
moving-on-map-entity state/movement protocol `Game::Vehicle` and the
player/event drivers build on. 14 of its own 16 real bytecode-defined
methods compile clean, needing no new opcode work either. The other 2
(`#initialize`, `#front_tile`) are both blocked by the same
non-mandatory-arity shape as every other non-embedding target already
shipped -- so, like `RPG2k::Scene::Base` above, its own provably-typed
ivars stay unembedded too.

**A second real, live bug, found by this round's own full-sweep
discipline, not either background agent's own new-class work.**
`IvarLayout.join` -- the fixed-point per-ivar type-join the whole
embedding-safety analysis (and `ArgTypes`' own call-site argument-type
inference, which reuses the identical join) is built on -- had an
UNKNOWN-poisoning bug:

```ruby
# before (buggy)
def self.join(a, b)
  return b if a.nil?
  return a if b == UNKNOWN || b.nil?   # <- kept the OLD concrete type
  return UNKNOWN if a != b
  a
end

# after (fixed)
def self.join(a, b)
  return b if a.nil?
  return UNKNOWN if b == UNKNOWN || b.nil?   # <- correctly poisons
  return UNKNOWN if a != b
  a
end
```

A `SETIV` (or call-site argument) site whose own value traced to UNKNOWN
used to have that contribution silently *discarded* whenever some
other, earlier-processed site for the same ivar name had already joined
in a concrete type -- directly contradicting this same class's own
top-of-file comment ("a single unknown-typed source... makes it
permanently dynamic"). Caught for real building `Game::Character`:
`#move_diagonal`'s own `@last_move_direction = [horizontal, vertical]`
(a genuine `Array` literal, correctly traced to UNKNOWN) was getting
silently dropped in favor of `#initialize`'s own earlier
`@last_move_direction = direction` (`:fixnum`) -- reported `EMBED
fixnum` for an ivar that can, on a real code path, hold an `Array`.

**Severity, checked directly against the generated codegen, not
assumed.** Not exploitable for `Game::Character` itself -- its own
`#initialize` never compiles at all, so the class-level
`drop_unsafe_embeddings` gate already refuses to embed anything for it
regardless of this bug. But a live, already-shipped bug for classes
whose own `#initialize` *does* compile: a fresh whole-program diagnostic
taken before and after the fix shows `Game::Screen` losing 11 of its
own previously-"embeddable" ivars (`@frames`, `@shake_power`,
`@shake_speed`, `@shake_frames`, `@shake_offset`, `@flash_frames`,
`@pan_x`, `@pan_y`, `@pan_step`, `@fade_frames`, `@fade_transition`) and
`Game::State` losing one (`@map_id`) -- confirmed directly against the
real generated `struct Game__Screen_ivars`/`struct Game__State_ivars`
field lists, which shrink from 21 to 10 fields and 13 to 12 fields
respectively. Both classes still keep several genuinely-sound embedded
ivars each, so neither drops out of "classes needing
`MRB_SET_INSTANCE_TT`" entirely -- the pre-fix set of embedded fields
for both was real, live, over-permissive `RData`-struct layout, not a
class of bug that never allocated the struct at all (the earlier
`Game::Actor` bug's own shape, true undefined behavior). Checked
directly against the emitted `SETIV` codegen for an embedded field: it
already carries a runtime `mrb_integer_p` guard that raises a real Ruby
`TypeError` on a non-`Integer` write, rather than writing through a
mismatched union/type punning -- so the pre-fix bug's real failure mode
was "a previously-working code path (a legitimate `Array` assignment to
a wrongly-embedded ivar) now raises `TypeError` at runtime", not silent
memory corruption. Real and worth fixing, but categorically less severe
than the `Game::Actor` bug.

**Full-sweep re-check** (all twenty now-shipped targets' own
entry-point counts, `NATIVE_SRCS` set): `Game::Picture` (25),
`Game::EnemyAction` (6), `Game::Screen` (41), `RPG2k::Window` (32),
`Game::Transition` (32), `Game::Actor` (76), `Game::Party` (85),
`RPG2k::Scene::MapViewer` (34), `Game::Battle` (75),
`RPG2k::Scene::ItemMenu` (41), `RPG2k::Scene::SkillMenu` (39),
`RPG2k::Scene::DebugMenu` (33), `RPG2k::Scene::EquipMenu` (29),
`RPG2k::Scene::Menu` (28), `Game::State` (23),
`RPG2k::Scene::StatusMenu` (13), `Game::MoveRoute` (18),
`RPG2k::Scene::ChipsetEditor` (17), `RPG2k::Scene::Base` (17),
`Game::Character` (14) -- all eighteen previously-shipped counts match
exactly; nothing moved except the two intentional (and now-verified)
ivar-count drops on `Game::Screen`/`Game::State` from the join() fix.

**Verified for real:** the real, opt-in `RPGMAKER_BC2CPP=1` build
succeeds end to end (`EXIT: 0`), with **zero** `-Winfinite-recursion`
warnings and **zero** compile errors anywhere in the log. `nm -C` on the
resulting `libmruby.a` shows all 31 new entry points (17
`RPG2k::Scene::Base_*_impl`, 14 `Game::Character_*_impl`) present and
externally linked, with every one of the eighteen already-shipped
classes' own method-entry-point symbol counts unchanged. Since
`rpg2k_compiled_gen.cpp` is regenerated from `bc2cpp.rb` by the real
`mrbgem.rake` prerequisite on every build (not hand-maintained), this
same real build is also direct, textual confirmation of the join() fix:
reading the generated `struct Game__Screen_ivars`/`struct
Game__State_ivars` definitions out of the post-fix build shows exactly
10 and 12 fields respectively, matching the fix's own predicted impact
field-for-field.

## Follow-up: RPG2k::Scene::SaveLoad, RPG2k::Scene::Order, and a real compile_send keyword/splat-argument silent-drop bug

Two more independent classes, plus a third real, live bug found by this
round's own dedicated adversarial bug hunt (a background agent tasked
purely with stress-testing already-shipped code, run in parallel with
the two new-class agents rather than sequentially after them).

**RPG2k::Scene::SaveLoad** (`mruby-rpg2k/mrblib/scene/save_load.rb`) is
the file-select screen shared by `Scene::Menu`'s own Save command and
`Scene::Title`'s Continue entry. 12 of its own 22 real bytecode-defined
methods compile clean, needing no new opcode work. `#initialize`
(`initialize parent, state, mode`) does not compile -- it opens with its
own `super parent` call into `RPG2k::Scene::Base` (the same SUPER gap
`RPG2k::Scene::ItemMenu`/`DebugMenu`/`Menu`/`ChipsetEditor` already hit,
now a fourth class this same SUPER-opcode lead would unlock) and also
builds `@slots` via a real `(1..SLOT_COUNT).map { |slot| ... }` block.
Since `#initialize` never compiles, its own provably-typed ivars (`@mode`,
Symbol; `@arrow_anim`, Fixnum) stay unembedded too.

**RPG2k::Scene::Order** (`mruby-rpg2k/mrblib/scene/order.rb`) is the
RPG2003 field Order screen -- a pick-and-place party reorder UI across a
left (remaining) / right (picked) column pair, plus a Confirm/Redo prompt
once every member has been picked. 12 of its own 16 real bytecode-defined
methods compile clean, needing no new opcode work. `#initialize` (`super
parent` as its own first statement) matches the same SUPER gap exactly --
a fifth class it would unlock. The other 3 gaps are each a genuine Ruby
block. No ivars embed, same reasoning as SaveLoad.

**A third real, live bug, found by a dedicated bug-hunt agent stress-
testing every already-shipped class, not by either new-class agent.**
`compile_send`'s own SEND/SSEND argument-count parsing used a bare
`/n=(\d+)/` regex against a call site's real mrbc disassembly. That
recognizes only a plain positional-argument shape (`"n=3"`), but mrbc's
own `print_args` (`src/codedump.c`) emits two other real shapes this
regex silently *misparsed instead of rejecting*: a keyword-argument call
site (`"n=3|nk=1"`, one Symbol/value register pair per keyword -- `src/
vm.c`'s own `OP_SEND` packs these into a real Hash *at runtime*, a step
this codegen never replicated at all) and a splat call site (`"n=*"`,
mrbc's own `CALL_MAXARGS` sentinel -- a genuinely variable argument count
this codegen has no fixed register list for). Neither shape matches
`/n=(\d+)/` (no digits right after `"n="` for a splat; the keyword pair
registers are simply never looked at for a keyword call), and
`nil.to_i` silently evaluated to 0 -- so a splat call site used to
compile to a real zero-argument `mrb_funcall`, silently dropping every
splatted argument, and a keyword call site compiled with only its real
positional arguments, silently dropping the keyword hash entirely.

**Confirmed live in six already-shipped, already-compiled methods, not
hypothetical:**
- `Game::Battle#enemy_basic_action`/`#enemy_fallback_attack`'s own
  `deal_attack(b, target, 0, charged: charged)` compiled with `charged:`
  silently dropped -- every charged enemy attack routed through either
  method called the real `#deal_attack` with its own `charged: nil`
  default instead of the caller's real charged state.
- `Game::Actor#knock_out!`/`Game::Battle#inflict_state`'s own
  `Game::States.prune(ids, table, keep: permanent_states)` silently
  dropped `keep:` -- a real permanently-protected state (e.g. an innate
  racial trait modeled as a state) could be pruned away as if no
  exemption list existed at all.
- `Game::Actor#restore_class`'s own `set_level(@level, preserve_mod:
  false)` silently called with `preserve_mod: true` instead -- a real,
  load-bearing inversion (the source's own adjacent comment explains why
  `false` is deliberate for a class restore, to avoid carrying stat
  modifiers across it).
- `RPG2k::Scene::DebugMenu#play_animation`'s own call into
  `RPG2k::Scene::Map#anim_target(tx, ty, height:, index:,
  flash_target:)` -- three real **mandatory** keyword parameters, no
  defaults at all -- used to silently compile a call that would raise a
  real `ArgumentError` (missing keyword) at runtime the moment it ran,
  not just pass a wrong value.

**Severity, and how this differs from the round's own IvarLayout.join
fix.** The `IvarLayout.join` bug (found two rounds ago, still worth
restating for contrast) was a wrong *embedding* decision caught by a
runtime `mrb_integer_p` type guard before it could do anything worse than
raise `TypeError` on a code path that used to work. This bug has no such
safety net: the generated C++ for all six methods above compiled and
linked completely cleanly either way -- nothing short of noticing the
real, wrong gameplay behavior (an enemy's charged attack behaving as
uncharged, a protected state being pruned, stat modifiers persisting
across a class change) would ever have caught it. This is the most
severe bug found across every round of this effort so far.

**Fix, applied at the root in `bc2cpp.rb`'s own `compile_send`:** now
parses `n=(\d+|\*)(?:\|nk=(\d+|\*))?` and refuses to compile (the same
loud `#error` fallback every other unmodeled shape here already gets,
leaving the method on the interpreter) whenever the match indicates a
splat or a keyword argument list, instead of silently mistranslating
either. `SEND0`/`SSEND0`'s own disassembly never prints `"n="` at all (a
real, always-zero-argument call, not a shape to reject), so a `nil` match
still means `n=0`, now explicit instead of incidental on `nil.to_i`.

**Consequence for already-shipped code:** all six affected methods above
are no longer registered in `mruby-rpg2k-compiled/src/register.cxx` --
each now correctly falls back to the interpreter, the same established
fallback every other out-of-scope shape already gets. `Game::Actor`'s own
entry-point count drops from 76 to 74 (`#knock_out!`/`#restore_class`),
`Game::Battle`'s from 75 to 72 (`#enemy_basic_action`/
`#enemy_fallback_attack`/`#inflict_state`), and `RPG2k::Scene::DebugMenu`'s
from 33 to 32 (`#play_animation`).

**Checked and found NOT live, deliberately not touched** (from this same
round's dedicated bug hunt): a `GETMCNST` name-extraction regex sharing
the same `$`-anchored shape a prior round already fixed for `GETCONST` --
checked all 1412 real `GETMCNST` sites in the closed world, none has a
trailing local-variable comment, so it never actually triggers today; a
structural gap where a `SETIV` inside a `BLOCK`/`SENDB` child irep is
invisible to `IvarLayout` (only TDEF-registered leaf bodies are visited)
-- confirmed zero live triggers against every currently-embedded ivar via
a full irep-tree walk, not just registered methods; `mrb_str_new_cstr`
truncating a STRING literal at an embedded NUL byte (`strlen` vs. the
byte-escaped length already computed) -- no such literal exists anywhere
in the closed world; GC safety of a plain C-local `mrb_value` across a
nested `mrb_funcall` -- confirmed safe directly against `mrb_vm_exec`'s
own arena save/restore in `3rd/mruby/src/vm.c`/`gc.c`, which never touches
a caller's own already-arena-pushed values.

**Full-sweep re-check** (all twenty-two now-shipped targets):
`Game::Picture` (25), `Game::EnemyAction` (6), `Game::Screen` (41),
`RPG2k::Window` (32), `Game::Transition` (32), `Game::Actor` (**74**,
down from 76), `Game::Party` (85), `RPG2k::Scene::MapViewer` (34),
`Game::Battle` (**72**, down from 75), `RPG2k::Scene::ItemMenu` (41),
`RPG2k::Scene::SkillMenu` (39), `RPG2k::Scene::DebugMenu` (**32**, down
from 33), `RPG2k::Scene::EquipMenu` (29), `RPG2k::Scene::Menu` (28),
`Game::State` (23), `RPG2k::Scene::StatusMenu` (13), `Game::MoveRoute`
(18), `RPG2k::Scene::ChipsetEditor` (17), `RPG2k::Scene::Base` (17),
`Game::Character` (14), `RPG2k::Scene::SaveLoad` (12),
`RPG2k::Scene::Order` (12) -- every count matches exactly, including the
three intentional (and now-verified) drops from the compile_send fix.

**Verified for real:** the real, opt-in `RPGMAKER_BC2CPP=1` build
succeeds end to end (`EXIT: 0`), with **zero** `-Winfinite-recursion`
warnings and **zero** compile errors. `nm -C` on the resulting
`libmruby.a` shows all 24 new entry points (12
`RPG2k::Scene::SaveLoad_*_impl`, 12 `RPG2k::Scene::Order_*_impl`) present
and externally linked; the six methods the compile_send fix stopped
compiling are confirmed absent by symbol name; and every one of the
twenty already-shipped classes' own entry-point counts either matches
exactly or drops by precisely the number of methods this round's own fix
predicted, with no other change anywhere.

## Follow-up: Game::Shop, and a real native-name-collision instance confirmed live

A fourteenth, independent round adds `Game::Shop`
(`mruby-rpg2k/mrblib/game.rb`) -- the RPG2000 buy/sell shop-menu backing
model: the stocked good list, buy/sell affordability and the 99-item
stack cap, half-price selling. 11 of its own 14 real bytecode-defined
methods compile clean, needing no new opcode work at all:
`#price`/`#name`/`#description`/`#equip?` each read one database row
(`@db.item[id]`, `AREF`-shaped) and `#equip?` also builds and tests a
Range literal (`RANGE_INC`) plus ordinary POLY dispatch on `#cover?`
(never devirtualized -- `#cover?` collides with mruby core's own native
`Range#cover?`); `#sellable_items` chains three ordinary POLY sends;
`#max_buy`/`#max_sell`/`#sell_price`/`#sellable?` are plain
arithmetic/conditional compositions of the above, `#sell_price` and
`#max_sell` each devirtualizing straight into `#price`'s/`#sellable?`'s
own `_impl` (MONO). The 3 gaps are the same two already-established
out-of-scope shapes: `#initialize` (a genuine Ruby block, `BLOCK`/
`SENDB`) and `#buy`/`#sell` (each with one non-mandatory optional
argument). Since `#initialize` never compiles, `drop_unsafe_embeddings`
correctly refuses to embed any of this class's own ivars.

**A real, concrete instance of the native-name-collision shape
`extract_native_method_names`' own `MRB_SYM_Q`/`_B`/`_E` macro coverage
protects against, confirmed live rather than by analogy:** `:name`
reports POLY (2 defs: `Game::Shop`, `<native>`) in this class's own
whole-program registry dump with `NATIVE_SRCS` set the same way
`mrbgem.rake` always does -- `Game::Shop#name` collides by bare name with
mruby core's own `Symbol#name`/`Class#name`, registered via
`src/symbol.c`'s own ROM method table. `#name` correctly stays ordinary
`mrb_funcall` dispatch in its own registration, never a direct call into
`Game__Shop_name_impl` from any other compiled call site in the whole
program.

**Full-sweep re-check:** all twenty-two previously-shipped targets' own
entry-point counts -- `Game::Picture` (25), `Game::EnemyAction` (6),
`Game::Screen` (41), `RPG2k::Window` (32), `Game::Transition` (32),
`Game::Actor` (74), `Game::Party` (85), `RPG2k::Scene::MapViewer` (34),
`Game::Battle` (72), `RPG2k::Scene::ItemMenu` (41),
`RPG2k::Scene::SkillMenu` (39), `RPG2k::Scene::DebugMenu` (32),
`RPG2k::Scene::EquipMenu` (29), `RPG2k::Scene::Menu` (28), `Game::State`
(23), `RPG2k::Scene::StatusMenu` (13), `Game::MoveRoute` (18),
`RPG2k::Scene::ChipsetEditor` (17), `RPG2k::Scene::Base` (17),
`Game::Character` (14), `RPG2k::Scene::SaveLoad` (12),
`RPG2k::Scene::Order` (12) -- match exactly; nothing moved.

**Verified for real:** the real, opt-in `RPGMAKER_BC2CPP=1` build
succeeds end to end (`EXIT: 0`), with **zero** compile errors and
**zero** `-Winfinite-recursion` warnings. `nm -C` on the resulting
`libmruby.a` shows all 11 new `Game__Shop_*_impl` entry points present
and externally linked, with every already-shipped class's own symbol
count unchanged.

## Follow-up: Game::Map, the fourth real embedding target

A fifteenth, independent round adds `Game::Map`
(`mruby-rpg2k/mrblib/game.rb`, reopened by `mruby-rpg2k/mrblib/game/
battle_support.rb`) -- one loaded map's own tile-layer data: dimensions/
chipset id, the lower/upper tile-id layer arrays, and Tile Substitution's
own per-layer old_id->new_id rewrite table. 12 of its own 13 real
bytecode-defined methods compile clean, needing no new opcode work at
all -- the opcode set fourteen rounds of this ADR had already built up
already covers every real shape this class's own method bodies use.
`#substitute_tile` is the one gap, confirmed against its own real
generated `#error` line, not assumed: it ends in two real
`@substitutions[idx].each { |k, v| ... }`/`rebuilt.each { |k, v| ... }`
blocks (`BLOCK`/`SENDB`), the same established out-of-scope shape every
other block-using method in this file already documents.

**`#initialize` compiles clean** (`initialize id, unit`, 2 purely
mandatory arguments, no `super`, no block) -- the fourth target, after
`Game::Screen`/`Game::Transition`/`Game::State` above, whose own ivars
get real `RData` struct embedding: `@id` (the annotated-fixnum first
argument) and `@revision` (a literal `0`, then only ever `+= 1`) are both
real, provably-Fixnum fields on a new `Game__Map_ivars` struct. Checked
directly against the exact `Game::Actor`-shaped embedding bug several
follow-ups up, not assumed safe by analogy: this class's own single real
construction site (`Game::Map.new id, LCF::MapUnit.new(...)`,
`mruby-rpg2k/mrblib/main.rb`'s own `#load_map`) always goes through the
compiled `#initialize` -- confirmed by grepping the whole closed world
for `Game::Map.new`/`.allocate`/a subclass and finding exactly that one
plain `.new` call site, no bypass, and no subclass anywhere. The other 7
real ivars (`@width`/`@height`/`@chipset_id` -- each `unit.<method>`, a
method call's own return value, never traced by this compiler's
Fixnum-literal-only inference; `@lower`/`@upper`/`@substitutions` --
Array/Hash literals; the two `@substitution_snapshot_*` cache fields,
also opaque) all stay `UNKNOWN` and so stay on the ordinary dynamic
`iv_tbl`, mixed safely on the same object with the two embedded fields,
the same mixed-embedding shape `Game::Screen`/`Game::Transition`/
`Game::State` already established.

`#set_tile`/`#tile` are `private` (a bare `private` mid-class-body in
`game.rb`'s own reopening, in effect through the end of it); `#initialize`
is forced private by mruby's own interpreter (the same real special case
every other compiled `#initialize` in this file already documents); every
other method -- including `#sync_layers_to_unit`, defined in the
*separate* `class Map` reopening in `battle_support.rb`, which starts its
own fresh, default-public visibility scope -- is public.

**Full-sweep re-check** (`NATIVE_SRCS` set the same way `mrbgem.rake`
computes it): all twenty-two previously-shipped targets' own entry-point
counts -- `Game::Picture` (25), `Game::EnemyAction` (6), `Game::Screen`
(41), `RPG2k::Window` (32), `Game::Transition` (32), `Game::Actor` (74),
`Game::Party` (85), `RPG2k::Scene::MapViewer` (34), `Game::Battle` (72),
`RPG2k::Scene::ItemMenu` (41), `RPG2k::Scene::SkillMenu` (39),
`RPG2k::Scene::DebugMenu` (32), `RPG2k::Scene::EquipMenu` (29),
`RPG2k::Scene::Menu` (28), `Game::State` (23),
`RPG2k::Scene::StatusMenu` (13), `Game::MoveRoute` (18),
`RPG2k::Scene::ChipsetEditor` (17), `RPG2k::Scene::Base` (17),
`Game::Character` (14), `RPG2k::Scene::SaveLoad` (12),
`RPG2k::Scene::Order` (12), `Game::Shop` (11) -- match exactly; nothing
moved.

**Verified for real:** the real, opt-in `RPGMAKER_BC2CPP=1` build
(`rake -f 3rd/mruby/Rakefile`, host target) succeeds end to end
(`EXIT: 0`), with **zero** compile errors and **zero**
`-Winfinite-recursion` warnings anywhere in the log. `nm -C` on the
resulting `libmruby.a` shows all 12 new `Game__Map_*_impl` entry points
present and externally linked, plus the new `Game__Map_ivars`/
`Game__Map_ivars_free`/`Game__Map_ivars_type` symbols confirming the real
embedding took effect (the generated `struct Game__Map_ivars` has exactly
the two predicted `mrb_int` fields, `revision` and `id`), with every
already-shipped class's own symbol count unchanged.

## Follow-up: Game::EnemyAi, Game::ChipSet (fifth real embedding target), and this compiler's most severe bug so far

Two more independent classes, plus a fourth real, live bug -- this one
the most severe found across the whole effort, not caught by a runtime
type guard the way the `IvarLayout.join` bug was, but a guaranteed
`NoMethodError` on some of the most common navigation code in the whole
codebase.

**Game::EnemyAi** (`mruby-rpg2k/mrblib/game/battle_support.rb`) is the
outside-world collaborator `Game::Battle`'s own enemy action-pattern
logic reads through: skill-table/database lookups, casting-eligibility/
effectiveness formulas reused from `Game::Party`, switch read/write, and
the party's own average level. 9 of its own 10 real bytecode-defined
methods compile clean, needing no new opcode work. `#initialize` (2
purely mandatory arguments, `db, state`, no `super`, no block) compiles
clean too, but neither of this class's own two ivars (`@db`, `@state`)
ever gets embedded: both are opaque object references, never provably
Fixnum/Symbol. The one gap, `#party_level`, ends in a real
`actors.each { |a| ... }` block (`BLOCK`/`SENDB`) -- an already-
established out-of-scope shape. **This one was caught during integration,
not by the round's own reporting**: the diff this round's own coverage
agent produced registered `#party_level` as if it compiled, but a direct
re-run of the real whole-program diagnostic (`SKIP_UNSUPPORTED=1`)
against the exact same source shows it silently dropped with no
generated entry point at all -- confirmed by reading `game/
battle_support.rb`'s own real source directly. Registering an
uncompiled method would have failed the build outright (`'...' was not
declared in this scope`), which is exactly what the first real build
attempt this round did -- caught and fixed before merge, not shipped.

**Game::ChipSet** (`mruby-rpg2k/mrblib/game.rb`) is one loaded chipset's
own tile graphic name plus the lower/upper tile-passability tables,
terrain table, and water-animation parameters (chipset chunks 11/12),
keyed by the tile-id-to-chip-index math the RPG2000 BlockA/B/C/D chipset
layout uses. **All 9** of its own real bytecode-defined instance methods
compile clean, needing no new opcode work -- the best ratio of any
target so far. `.lower_index` is a real singleton method (`def
self.lower_index`), structurally invisible to `build_registry`'s own
CLASS/MODULE/TDEF walk (the same pre-existing gap `Game::MoveRoute`'s own
class methods already documented), so it stays interpreted; every
compiled method that calls it correctly falls back to ordinary
`mrb_funcall` rather than being unsoundly devirtualized.

`#initialize` (`initialize db, id`) compiles clean -- pure mandatory
arity, no `super`, no block -- the **fifth** target after `Game::Screen`/
`Game::Transition`/`Game::State`/`Game::Map` above whose own ivars get
real `RData` struct embedding. Checked directly against the exact
`Game::Actor`-shaped embedding bug several follow-ups up: grepping the
whole closed world for `ChipSet.new`/`Game::ChipSet.new`/`.allocate`/a
subclass finds only plain two-argument `.new(db, id)` call sites
(`mruby-rpg2k/mrblib/scene/map.rb`, `scene/map_viewer.rb`, `game/
lsd_io.rb`, plus this project's own `scripts/*_check.rb` harnesses) and
no subclass anywhere. `@animation_type`/`@animation_speed` (each
`c.animation_type || 0`/`c.animation_speed || 0`, both real, provably-
Fixnum) embed into a new `Game__ChipSet_ivars` struct; the real generated
`#initialize` was confirmed to actually call `mrb_data_init` before
trusting this. The other 5 ivars (`@name`/`@graphic` -- String-valued
method-call return values; `@passable_lower`/`@passable_upper`/`@terrain`
-- Array-typed) stay `UNKNOWN` and remain on the ordinary `iv_tbl`, mixed
safely with the two embedded fields.

**The most severe real, live bug found in this whole effort, caught
building this class's own `#passable_tile?`/`#landable_tile?`** (both do
a real `flags & DIR_BIT[dir]`/`flags & ALL_DIRS`/`flags & ABOVE_BIT` --
an ordinary `Integer#&` send). Every SEND-name-extraction regex in
`bc2cpp.rb` (four copies: `build_registry`'s visibility tracking,
`compile_send` itself, `ArgTypes.analyze`'s call-site walk, and
`trace_new_target`) used the same character class,
`[\w+\-*\/<>=!?\[\]]` -- and that class omitted every bitwise/unary
operator character (`&`, `|`, `^`, `~`, `%`, and the unary-method suffix
`@` for `-@`/`+@`). A `SEND` to one of those names matched *nothing*
after the colon, so `name` came back `nil` -- silently interpolated as
`""` into the generated `mrb_funcall(M, recv, "", n, ...)` call, an
empty-string method name no real Ruby method ever has. That compiles and
links completely clean (the same class of bug as this ADR's own earlier
`?`-omission fix -- a `#error`-marker check can never catch it) but
raises a real `NoMethodError` the first time it actually runs, with no
runtime type guard to soften the blow the way the `IvarLayout.join` bug
had.

**Confirmed live and, independently, far more widespread than the
triggering case**: a direct grep of the real generated
`rpg2k_compiled_gen.cpp` (built from the *unfixed* `bc2cpp.rb`, before
this round's own fix) for the exact broken
`mrb_funcall(M, <reg>, "", ...)` shape found **41 call sites across 32
distinct, already-registered compiled methods spanning a dozen already-
shipped classes** -- not just `RPG2k::Scene::ChipsetEditor`'s own
`#toggled_byte`/`#cell_color_for`. By far the most common shape is `%`
used for cursor-wraparound arithmetic (`(index + delta) % list.size` /
`@cursor_index %= @names.size`), hit by `RPG2k::Scene::Order#
move_cursor`; `RPG2k::Scene::EquipMenu#move_slot_cursor`/
`#update_slots`/`#refresh_cand_cursor`/`#tick_arrows`;
`RPG2k::Scene::ItemMenu#refresh_item_cursor`/`#refresh_teleport_cursor`/
`#tick_arrows`/`#update_target`/`#draw_target_face`; the identical five on
`RPG2k::Scene::SkillMenu`; `RPG2k::Scene::Menu#update_command`/
`#update_actor_selection`/`#draw_actor_face`;
`RPG2k::Scene::StatusMenu#draw_actor_face`;
`RPG2k::Scene::DebugMenu#cycle_mode`/`#move_block`/`#move_row`/
`#update_editor`; `RPG2k::Scene::SaveLoad#tick_arrows`/
`#build_face_cell`; `RPG2k::Scene::Base#advance_list_arrow_anim`;
`RPG2k::Window#update`; `Game::Screen#update_shake` (a `% 256` phase
wrap); `Game::Transition#block_shuffle_rank` (`% total`); and
`RPG2k::Scene::ChipsetEditor#draw_cursor`/`#move_cursor` (`@idx % COLS`)
themselves. The remaining two sites are the triggering `&`/`|`/`~`
bitwise work in `ChipsetEditor#toggled_byte`/`#cell_color_for`. In other
words: every already-shipped menu's own scrolling-cursor/blink-arrow
logic -- the single most common UI idiom in this entire codebase, not an
edge case -- was silently compiling to a guaranteed crash the moment a
player actually scrolled a list or moved a cursor, in a build that
compiled and linked with zero warnings.

Fixed at the root: the character class extended to
`[\w+\-*\/<>=!?\[\]&|^~%@]` in all four occurrences (kept in sync even
where the surrounding logic could never actually be affected by an
operator name, e.g. `trace_new_target`'s own `name == 'new'` check).
Verified directly, not just reasoned about: regenerating with the
*unfixed* regex reproduces `mrb_funcall(M, r4, "", 1, r5)` verbatim;
regenerating with the fix in place shows the correct
`mrb_funcall(M, r4, "&", 1, r5)` (`ChipsetEditor#toggled_byte`) and
`mrb_funcall(M, r3, "%", 1, r4)` (`RPG2k::Scene::Order#move_cursor`). The
very next regen of every affected class's own generated output picks up
the fix automatically -- no hand-edit to any registration block was
needed beyond this round's own two new classes, the same "fix
`bc2cpp.rb` once, every affected class regenerates correctly" shape the
`IvarLayout.join` fix already established.

**Full-sweep re-check** (all twenty-six now-shipped targets):
`Game::Picture` (25), `Game::EnemyAction` (6), `Game::Screen` (41),
`RPG2k::Window` (32), `Game::Transition` (32), `Game::Actor` (74),
`Game::Party` (85), `RPG2k::Scene::MapViewer` (34), `Game::Battle` (72),
`RPG2k::Scene::ItemMenu` (41), `RPG2k::Scene::SkillMenu` (39),
`RPG2k::Scene::DebugMenu` (32), `RPG2k::Scene::EquipMenu` (29),
`RPG2k::Scene::Menu` (28), `Game::State` (23),
`RPG2k::Scene::StatusMenu` (13), `Game::MoveRoute` (18),
`RPG2k::Scene::ChipsetEditor` (17), `RPG2k::Scene::Base` (17),
`Game::Character` (14), `RPG2k::Scene::SaveLoad` (12),
`RPG2k::Scene::Order` (12), `Game::Shop` (11), `Game::Map` (12),
`Game::EnemyAi` (9), `Game::ChipSet` (9) -- every count matches exactly
(including `RPG2k::Scene::ChipsetEditor`'s own unchanged 17: the operator
fix changes what two already-registered methods' bodies *compute*, never
how many methods compile or their arity/visibility).

**Verified for real:** the real, opt-in `RPGMAKER_BC2CPP=1` build
succeeds end to end (`EXIT: 0`), with **zero** compile errors and
**zero** `-Winfinite-recursion` warnings. `nm -C` on the resulting
`libmruby.a` shows all 19 new entry points (9 `Game__EnemyAi_*_impl`, 9
`Game__ChipSet_*_impl`) present and externally linked, plus the new
`Game__ChipSet_ivars`/`_free`/`_type` symbols (the generated struct has
exactly the two predicted `mrb_int` fields, `animation_type` and
`animation_speed`); a direct grep of the post-fix generated
`rpg2k_compiled_gen.cpp` for the broken `mrb_funcall(M, <reg>, "", ...)`
shape returns **zero** matches (down from 41); and every already-shipped
class's own symbol count is unchanged.

## Follow-up: Game::Timer, Game::Switches, Game::Variables (sixth real embedding target)

Three more independent classes, both this round's own agents
independently re-deriving and re-verifying the operator-regex fix above
against their own (stale) base before adding coverage -- confirmed
byte-identical to the already-shipped fix, so no duplicate was applied,
just each round's own new-class work merged onto the real current tip.

**Game::Timer** (`mruby-rpg2k/mrblib/game.rb`) is the RPG2000 Timer/
Timer2 countdown backing model -- both are real instances of this one
class, held as `Game::State`'s own `@timers` array; there is no separate
"Timer2" class anywhere in the closed world. 7 of its own 10 real
bytecode-defined methods compile clean, needing no new opcode work --
this class is exactly the shape the operator-regex bug was found in:
`#display_text`'s own `s % 60` compiles to a real `Integer#%` send,
confirmed directly against the real generated output
(`mrb_funcall(M, r4, "%", 1, r5)`, never the pre-fix empty-string-name
shape). `#start`/`#tick`/`#drawn?` each have one non-mandatory optional
argument. `#initialize` compiles clean (zero arguments, pure mandatory
arity), but the whole-program EMBED diagnostic proposes nothing for this
class: `@running`/`@visible`/`@in_battle` are booleans (a type this
compiler's embedding lattice doesn't model), and `@frames` -- despite a
literal-Fixnum source in `#initialize` (`0`) and `#set` (`seconds * FPS +
...`) -- gets poisoned back to `UNKNOWN` by `#load_h`'s own
`h[:frames] || 0` (a real opaque `Hash#[]` read on a caller-provided
Hash), the same `IvarLayout.join` fixed-point poisoning behaviour the
earlier round's own join() bugfix established -- a nice real-world
confirmation that fix still works correctly on exactly the shape it was
designed for. Real full-sweep synergy: `:seconds`/`:display_text` are
both MONO (`Game::Timer` is their one and only real bytecode definition
anywhere), so already-shipped `Game::State#timer_seconds`/
`#timer2_seconds`/`#timer_display_text` now devirtualize straight into
`Game__Timer_seconds_impl`/`Game__Timer_display_text_impl`, confirmed
directly against the real regenerated output.

**Game::Switches** and **Game::Variables** (same file) are the
1-indexed boolean/integer flag stores an event page's conditions read
from, each backed by a plain Hash. Neither class's own method bodies use
a bitwise/modulo operator at all (`Switches#flip`'s own `!self[id]` is a
real SEND too, to `!`, but that character was already in the pre-fix
charset) -- re-checked specifically for the operator-regex bug's own
shape given how recently it shipped, confirmed by a zero-match grep of
the freshly regenerated output for the empty-name
`mrb_funcall(M, <reg>, "", ` shape project-wide.

All 7 of `Game::Switches`'s own real bytecode-defined methods compile
clean (`#revision`/`#dirty` are `attr_reader`-generated, native,
invisible to `bc2cpp` the same way every other `attr_reader`/
`attr_writer` in this codebase is). `#initialize`
(`initialize; @data = {}; @revision = 0; @dirty = {}; end`) compiles
clean -- zero arguments, no `super`, no block -- so its own provably-
Fixnum `@revision` gets real `RData` struct embedding, the **sixth**
target after `Game::Screen`/`Game::Transition`/`Game::State`/`Game::Map`/
`Game::ChipSet` above. Checked directly against the exact
`Game::Actor`-shaped embedding bug several follow-ups up: grepping the
whole closed world for `Switches.new`/`Game::Switches.new`/`.allocate`/a
subclass finds exactly two real construction sites
(`Game::State#initialize`'s own `@switches = Switches.new`, and this
project's own `scripts/export_nano7_map.rb` harness), both plain
zero-argument `.new` calls, no bypass and no subclass anywhere.
`@data`/`@dirty` (Hash literals) stay `UNKNOWN`.

`Game::Variables` has 6 real bytecode-defined methods, but `#initialize`
(`initialize(rpg2003 = false)`) has one non-mandatory optional argument
-- the same established out-of-scope shape every other unembedded target
documents -- so `drop_unsafe_embeddings` correctly refuses to embed this
class's own provably-Fixnum `@revision` too. The other 5 methods compile
clean, needing no new opcode work -- `#[]=`'s own clamp against
`@max`/`@min` is a plain pair of `>`/`<` comparisons already covered by
the existing `EQ`/`LT`/`LE`/`GT`/`GE` opcode work.

**Full-sweep re-check** (all twenty-nine now-shipped targets): every
previously-shipped class's own entry-point count matches exactly --
`Game::Picture` (25), `Game::EnemyAction` (6), `Game::Screen` (41),
`RPG2k::Window` (32), `Game::Transition` (32), `Game::Actor` (74),
`Game::Party` (85), `RPG2k::Scene::MapViewer` (34), `Game::Battle` (72),
`RPG2k::Scene::ItemMenu` (41), `RPG2k::Scene::SkillMenu` (39),
`RPG2k::Scene::DebugMenu` (32), `RPG2k::Scene::EquipMenu` (29),
`RPG2k::Scene::Menu` (28), `Game::State` (23),
`RPG2k::Scene::StatusMenu` (13), `Game::MoveRoute` (18),
`RPG2k::Scene::ChipsetEditor` (17), `RPG2k::Scene::Base` (17),
`Game::Character` (14), `RPG2k::Scene::SaveLoad` (12),
`RPG2k::Scene::Order` (12), `Game::Shop` (11), `Game::Map` (12),
`Game::EnemyAi` (9), `Game::ChipSet` (9) -- nothing moved; new:
`Game::Timer` (7), `Game::Switches` (7), `Game::Variables` (5).

**Verified for real:** the real, opt-in `RPGMAKER_BC2CPP=1` build
succeeds end to end (`EXIT: 0`), with **zero** compile errors, **zero**
`-Winfinite-recursion` warnings, and **zero** matches for the broken
empty-name `mrb_funcall(M, <reg>, "", ` shape (re-checked explicitly as
part of this round's own verification discipline, not just assumed from
the prior round's fix). `nm -C` on the resulting `libmruby.a` shows all
19 new entry points (7 `Game__Timer_*_impl`, 7 `Game__Switches_*_impl`,
5 `Game__Variables_*_impl`) present and externally linked, plus the new
`Game__Switches_ivars`/`_free`/`_type` symbols (the generated struct has
exactly the one predicted `mrb_int` field, `revision`, and
`Game__Switches_initialize_impl` really calls `mrb_data_init`), with
every already-shipped class's own symbol count unchanged.

## Follow-up: RPG2k::Scene::Title, RPG2k::Scene::MapWorld

Two more independent classes; both this round's own agents built with a
strengthened verification discipline given the prior two rounds' own
mistakes (the empty-method-name operator bug, and a method wrongly
registered despite never compiling) -- explicitly instructed to grep the
generated output for the broken `mrb_funcall(M, <reg>, "", ` shape and to
cross-check every registered method against the diagnostic's own printed
entry-point list before trusting it. Both re-confirmed zero matches for
the former and a clean cross-check for the latter.

**RPG2k::Scene::Title** (`mruby-rpg2k/mrblib/scene/title.rb`) is the
title screen's New Game/Continue/Exit menu. Only 6 of its own 20 real
bytecode-defined methods compile clean: `#update`/`#dispose` (public)
plus 4 private methods (`#refresh_cursor`, `#move_selection`,
`#auto_select?`, `#auto_new_game?`). `#move_selection`'s own real
`# bc2cpp: (fixnum)` annotation (already present in the source) lets its
`% @menu_items.length` wraparound arithmetic compile to a real,
non-empty `mrb_funcall(M, r3, "%", 1, r4)` -- re-checked directly given
this exact shape is this ADR's own most severe previously-found bug.
`#auto_select?`'s own real string-interpolated `$stderr.puts` calls
needed no new opcode either -- `STRING`/`STRCAT` support already existed.

The other 14 real methods split into the two already-established
out-of-scope shapes: 13 each have a real `rescue StandardError` clause;
`#initialize` itself hits two separate gaps in the same body -- a real
`super parent` call (`SUPER`, the same gap `ItemMenu`/`DebugMenu`/
`Menu`/`ChipsetEditor`/`SaveLoad`/`Order`'s own `#initialize` already
document) *and* a real `@menu_items.each_with_index do |item, index|
... end` block (`BLOCK`/`SENDB`) later on -- confirmed directly against
the real generated output showing both `#error` markers in the same
(unemitted) body. `#initialize` never compiling means
`drop_unsafe_embeddings` correctly refuses to embed any of this class's
own ivars (its own `@title`/`@window` ivars each get a devirtualization-
only `CLASS_HINT`, `Sprite`/`Window` respectively, never embedded).
`#refresh_cursor` is genuinely POLY at every real call site
(`RPG2k::Scene::Menu` defines a same-named method too), so
`#move_selection`'s own call into it correctly stays ordinary
`mrb_funcall` dispatch rather than being devirtualized.

**RPG2k::Scene::MapWorld** (`mruby-rpg2k/mrblib/scene/base.rb`) is the
small adapter `Scene::Map`'s own `#initialize` builds (`@world =
MapWorld.new(self, @rng)`) to bridge `Game::MoveRoute`/`Game::MoveType`'s
own small `world` protocol (passability, hero position, switch/sound
side effects, randomness) onto the owning scene and its `Game::State`,
without either movement-engine class needing a direct `Scene::Map`
reference. 7 of its own 8 real bytecode-defined methods compile clean:
`#initialize`, `#passable?`, `#can_land?`, `#hero_position` (an Array
literal off two chained sends), `#in_sight?`, `#set_switch` (`SETIDX`'s
own real `mrb_funcall(..., "[]=", ...)` fallback, since the real
receiver -- `Game::Switches` -- is never a raw Array/Hash), and
`#random`. The one gap, `#play_sound`, has a real `rescue
StandardError` clause; it already carries a real
`# bc2cpp: (String, , , )` magic-comment annotation predating this
round, which resolves to no actual type claim since this compiler's
annotation parser only recognizes fixnum/symbol tokens, never String --
moot either way, since the rescue clause alone keeps it interpreted.

`#initialize` (`initialize scene, rng`) compiles clean -- pure mandatory
arity, no `super`, no block -- but neither of this class's own two ivars
(`@scene`, `@rng`) ever gets embedded: both are opaque object references
(a `RPG2k::Scene::Map` and a `Game::Rng` instance respectively), never
provably Fixnum/Symbol. Every real construction site in the whole closed
world goes through a plain `MapWorld.new(scene, rng)` call --
`mruby-rpg2k/mrblib/scene/map.rb`'s own real construction site plus one
in this project's own `scripts/rpg2k_scene_check.rb` CRuby test harness
-- confirmed by grepping the whole closed world for `MapWorld.new`/
`.allocate`/a subclass and finding no bypass and no subclass anywhere.

**A concrete lead for a future round**: every one of
`#passable?`/`#can_land?`/`#hero_position`/`#play_sound`/`#random`/
`#set_switch` is a genuinely POLY name in the whole-program registry --
`RPG2k::Scene::VehicleWorld` (the same file, right below `MapWorld`, "the
same `world` protocol... for a Move Event/Set Move Route driving a
vehicle") defines every one of them too, an identical-shaped adapter
class not yet covered.

**Full-sweep re-check** (all thirty-one now-shipped targets): every
previously-shipped class's own entry-point count matches exactly --
`Game::Picture` (25), `Game::EnemyAction` (6), `Game::Screen` (41),
`RPG2k::Window` (32), `Game::Transition` (32), `Game::Actor` (74),
`Game::Party` (85), `RPG2k::Scene::MapViewer` (34), `Game::Battle` (72),
`RPG2k::Scene::ItemMenu` (41), `RPG2k::Scene::SkillMenu` (39),
`RPG2k::Scene::DebugMenu` (32), `RPG2k::Scene::EquipMenu` (29),
`RPG2k::Scene::Menu` (28), `Game::State` (23),
`RPG2k::Scene::StatusMenu` (13), `Game::MoveRoute` (18),
`RPG2k::Scene::ChipsetEditor` (17), `RPG2k::Scene::Base` (17),
`Game::Character` (14), `RPG2k::Scene::SaveLoad` (12),
`RPG2k::Scene::Order` (12), `Game::Shop` (11), `Game::Map` (12),
`Game::EnemyAi` (9), `Game::ChipSet` (9), `Game::Timer` (7),
`Game::Switches` (7), `Game::Variables` (5) -- nothing moved; new:
`RPG2k::Scene::Title` (6), `RPG2k::Scene::MapWorld` (7).

**Verified for real:** the real, opt-in `RPGMAKER_BC2CPP=1` build
succeeds end to end (`EXIT: 0`), with **zero** compile errors, **zero**
`-Winfinite-recursion` warnings, and **zero** matches for the broken
empty-name `mrb_funcall(M, <reg>, "", ` shape. `nm -C` on the resulting
`libmruby.a` shows all 13 new entry points (6
`RPG2k::Scene::Title_*_impl`, 7 `RPG2k::Scene::MapWorld_*_impl`) present
and externally linked, with every already-shipped class's own symbol
count unchanged.

## Follow-up: RPG2k::Scene::VehicleWorld (third Symbol-embedding target), Game::TextReveal, and a checked-but-not-live attr_reader registry gap

Two more independent classes, directly following up on the concrete
lead the prior round's own agent found.

**RPG2k::Scene::VehicleWorld** (`mruby-rpg2k/mrblib/scene/base.rb`,
defined right below `MapWorld`) is the same `world` protocol adapter
`MapWorld` exposes to the movement engine, adapted for a Move Event/Set
Move Route driving a vehicle (boat/ship/airship) instead of the hero:
passability/landing route through `Scene::Map#vehicle_char_passable?`/
`#vehicle_char_can_land?` (each carrying an extra `@type` argument)
instead of `MapWorld`'s own `#char_passable?`/`#char_can_land?`, and
there is no `#in_sight?` counterpart at all (not a gap -- Approach/Away
from Player is not a valid Move Type for a vehicle's own Set Move
Route). 6 of its own 7 real bytecode-defined methods compile clean,
needing no new opcode work. `#play_sound` is the one gap, the same
already-established `rescue StandardError` shape as `MapWorld`'s own
identically-named method.

`#initialize` (`initialize(scene, rng, type)`, already carrying a real
`# bc2cpp: (RPG2k::Scene::Map, Game::Rng, Symbol)` annotation) compiles
clean -- 3 purely mandatory arguments, no `super`, no block -- so its
own `@type` ivar (always a literal Symbol from `Game::Vehicle::TYPES`)
gets real `RData` struct embedding: the **third** Symbol-embedding
target, after `Game::ChipSet`/`Game::Switches`'s own Fixnum embeddings
established the mechanism. Checked directly against the exact
`Game::Actor`-shaped embedding bug several follow-ups up: grepping the
whole closed world for `VehicleWorld.new`/`.allocate`/a subclass finds
exactly one real construction site (`mruby-rpg2k/mrblib/scene/map.rb`'s
own `#load_map`, inside a `Game::Vehicle::TYPES.each_with_object` loop),
a plain three-argument `.new` call, no bypass and no subclass anywhere;
the real generated `#initialize` body was confirmed to call
`mrb_data_init` before any other statement. `@scene`/`@rng` stay opaque
object references, never embedded.

**A real, whole-program MONO/POLY registry-soundness gap, checked and
confirmed NOT live**, found while verifying `#set_switch`'s own
`@scene.state.switches[id] = on`: `:switches` has exactly one
bytecode-visible definition anywhere in the closed world
(`Game::Interpreter#switches`, itself `@state.switches`), so an
*unrestricted* whole-program diagnostic (no `ONLY_OWNERS`) reports it
MONO and would devirtualize this call straight into
`Game__Interpreter_switches_impl` -- but every real call site in the
whole codebase actually sends it to a `Game::State` instance, whose own
real `:switches` is an `attr_reader` installed at runtime via a Symbol
argument to `Module#attr_reader`, never a literal `mrb_define_method`-
family call site, so it is structurally invisible to
`extract_native_method_names`'s own regex-based scanner regardless of
`NATIVE_SRCS`. Had this actually been devirtualized, it would be real
infinite recursion (`Game::Interpreter#switches`' own body would call
right back into itself when invoked with a `Game::State` receiver,
confirmed directly against the real generated code) -- the same failure
mode `Game::MoveRoute#empty?` already documented, against a different
structural blind spot (`attr_reader`/`attr_writer`, not a native
`mrb_define_method` call site or an `MRB_MT_ENTRY`/`MRB_SYM(_Q/_B/_E)`
ROM-table entry, the two shapes `extract_native_method_names` already
covers).

**Verified NOT live in the real build, not just reasoned about**:
`Game::Interpreter` is not in this gem's own `ONLY_OWNERS` (nor any other
compiled gem's `OTHER_OWNERS`), so `compile_send`'s own already-
established owner-not-emitted guard correctly refuses the
devirtualization and falls back to ordinary `mrb_funcall` -- confirmed
directly against the real generated output: `#set_switch`'s own
`.switches` send compiles to plain `mrb_funcall(M, r5, "switches", 0)`,
marked `POLY`, never a direct call. Flagged for whoever next adds
`Game::Interpreter` (or any other `attr_reader`-heavy class) to a
compiled gem's own owners list -- `extract_native_method_names` would
need a third scanning mode (a literal `attr_reader`/`attr_writer`/
`attr_accessor` call-site scan across every real `.rb` source file, not
just C/C++) before that could ever be safe.

**Game::TextReveal** (`mruby-rpg2k/mrblib/game.rb`) is the message-
window character-by-character text reveal/typewriter-effect backing
model (`\!`/`\.`/`\|` pause markers, `\^` auto-close, `\>`...`\<`
instant spans, `\s[n]` speed changes). Only 6 of its own 11 real
bytecode-defined methods compile clean: `#auto_close?`, `#done?` (a
plain GE compare against `@total`), `#reveal_all` (a MONO self-call into
`#next_pause`, a Hash `#[]` GETIDX read, and a ternary), `#next_pause`
(an Array GETIDX read), `#pending_pause` (the same Array GETIDX read
plus a Hash `#[]` GETIDX read and a GE compare), and `#release_pause` (a
MONO self-call into `#pending_pause` plus an ADDI increment).
`#initialize` (five optional arguments) and `#advance` (one optional
argument) both have the established non-mandatory-arity gap;
`#speed_at`, `#through_instant` and `#visible_lines` each end in a
genuine Ruby block. `#initialize` never compiling means
`drop_unsafe_embeddings` correctly refuses to embed any of this class's
own ivars, even though the raw, class-blind `IvarLayout` analysis
proposes two (`@total`/`@released`, both provably-Fixnum).

**Full-sweep re-check** (all thirty-three now-shipped targets): every
previously-shipped class's own entry-point count matches exactly --
`Game::Picture` (25), `Game::EnemyAction` (6), `Game::Screen` (41),
`RPG2k::Window` (32), `Game::Transition` (32), `Game::Actor` (74),
`Game::Party` (85), `RPG2k::Scene::MapViewer` (34), `Game::Battle` (72),
`RPG2k::Scene::ItemMenu` (41), `RPG2k::Scene::SkillMenu` (39),
`RPG2k::Scene::DebugMenu` (32), `RPG2k::Scene::EquipMenu` (29),
`RPG2k::Scene::Menu` (28), `Game::State` (23),
`RPG2k::Scene::StatusMenu` (13), `Game::MoveRoute` (18),
`RPG2k::Scene::ChipsetEditor` (17), `RPG2k::Scene::Base` (17),
`Game::Character` (14), `RPG2k::Scene::SaveLoad` (12),
`RPG2k::Scene::Order` (12), `Game::Shop` (11), `Game::Map` (12),
`Game::EnemyAi` (9), `Game::ChipSet` (9), `Game::Timer` (7),
`Game::Switches` (7), `Game::Variables` (5), `RPG2k::Scene::Title` (6),
`RPG2k::Scene::MapWorld` (7) -- nothing moved; new: `Game::TextReveal`
(6), `RPG2k::Scene::VehicleWorld` (6).

**Verified for real:** the real, opt-in `RPGMAKER_BC2CPP=1` build
succeeds end to end (`EXIT: 0`), with **zero** compile errors, **zero**
`-Winfinite-recursion` warnings, and **zero** matches for the broken
empty-name `mrb_funcall(M, <reg>, "", ` shape. `nm -C` on the resulting
`libmruby.a` shows all 12 new entry points (6 `Game__TextReveal_*_impl`,
6 `RPG2k::Scene::VehicleWorld_*_impl`) present and externally linked,
plus the new `RPG2k::Scene::VehicleWorld_ivars`/`_free`/`_type` symbols
(the generated struct has exactly the one predicted `mrb_sym` field,
`type`, and `RPG2k__Scene__VehicleWorld_initialize_impl` really calls
`mrb_data_init`), with every already-shipped class's own symbol count
unchanged.

## Follow-up: RPG2k::Scene::EventResolver, Game::NumberInput, and this compiler's third severe bug -- a live, already-shipped devirtualization-soundness gap for attr_reader/attr_writer/attr_accessor

A twenty-fourth, independent round adds two more small coverage targets,
both needing zero new opcode work, plus a dedicated adversarial bug-hunt
pass across the whole existing `bc2cpp.rb` (not a coverage round) run in
parallel with them. That pass found and fixed a real, live, already-shipped
bug: a third instance of the "compiles and links clean but silently
generates wrong code" shape, this time in the MONO/POLY devirtualization
registry itself rather than in code generation, and unlike the two prior
severe bugs (the keyword/splat argument-count mis-parse, the bitwise/modulo
operator-name character-class gap), this one could crash a real running
game, not just misbehave.

**The bug:** `build_registry`'s bytecode walk sees a class's own `private`/
`protected`/`public` visibility-modifier sends and, before this fix,
treated every other bare-Symbol-argument send the same way it always had --
which is to say, it didn't see `attr_reader`/`attr_writer`/`attr_accessor`
sends as installing new methods at all. `Module#attr_reader` is itself a
native (C-implemented) method, so the getter it installs never gets a TDEF
of its own in any class's bytecode -- `build_registry`'s walk has no other
way to learn that name exists as a method on that class. This is the exact
same "invisible to a bytecode-only registry" gap `extract_native_method_names`
already exists to close for `mrb_define_method`-family call sites in
`NATIVE_SRCS` -- except here the installed name isn't a fixed literal
anywhere in C source; it's whatever Symbol argument *that specific call
site* happens to pass, so no amount of scanning `NATIVE_SRCS` could ever
find it. The result: if some name has exactly one real bytecode `def`
anywhere in the whole program, `monomorphic_target` calls it MONO and lets
a compiled caller devirtualize straight into that one class's own `_impl`
-- even when a *different* class defines the very same name via
`attr_reader`/`attr_writer`/`attr_accessor`, invisible to the scan that
declared it MONO in the first place.

**Confirmed live, not hypothetical, in code already shipped to `master` --
two separate instances, both already-registered compiled methods, not just
one:**

`Game::Actor#crit_chance` (`mruby-rpg2k/mrblib/game.rb`) is a real bytecode
`def crit_chance; weapon_crit_chance(weapon_crit_bonus); end` -- the *only*
bytecode-visible definition of `:crit_chance` anywhere in the closed world.
`Game::Enemy#crit_chance` (`mruby-rpg2k/mrblib/game/battle_support.rb`) is
`attr_reader :crit_chance, :attribute_ranks, :state_ranks` -- a second,
real definition the old scan never saw. `Game::Battle#critical?(b)`
(`mruby-rpg2k/mrblib/game/battle.rb:3409`, `@rng.random(100) <
(b.crit_chance || 0)`) is called with `b` a battler that can be *either* a
`Game::Actor` or a `Game::Enemy` (the source's own surrounding comment says
so explicitly). `Game::Battle` and `Game::Actor` are both already
compiled-gem owners, and `Game::Battle#critical?` is already registered
and shipped (`mruby-rpg2k-compiled/src/register.cxx`). Before this fix, the
real generated `Game__Battle_critical__impl` devirtualized `b.crit_chance`
straight into `Game__Actor_crit_chance_impl` -- which calls the
Actor-only `#weapon_crit_bonus` on `self` -- unconditionally, regardless of
`b`'s actual runtime class. The moment `b` is really a `Game::Enemy` (which
has no `#weapon_crit_bonus`), that's a real `NoMethodError`, crashing every
enemy attack's own critical-hit roll, in a build that compiles and links
clean with zero warnings.

Independently, `RPG2k::Window#transparent=(v)` (`mruby-rpg2k/mrblib/main.rb`)
is a real bytecode `def transparent=(v); @transparent = v ? true : false;
draw_skin; v; end` -- the *only* bytecode-visible definition of
`:transparent=` anywhere in the closed world. `Game::Actor` only has
`attr_accessor :transparent` (`mruby-rpg2k/mrblib/game.rb:1515`) -- a
second, real definition the old scan never saw. `Game::Party
#apply_actor_meta(actor, m)` (`mruby-rpg2k/mrblib/game.rb:3831`, `actor.
transparent = m[:transparent] unless m[:transparent].nil?`) is called with
`actor` a real `Game::Actor` -- never a `Window`. `Game::Party` and
`Game::Actor` are both already compiled-gem owners, and `#apply_actor_meta`
is already registered and shipped. Before this fix, the real generated
`Game__Party_apply_actor_meta_impl` devirtualized `actor.transparent = ...`
straight into `RPG2k__Window_transparent__impl` -- which calls the
Window-only `#draw_skin` on `self` -- unconditionally. Since `actor` here
is never anything but a `Game::Actor`, this one is not merely a
theoretical risk gated on which subclass happens to reach the call site
(unlike `#critical?`'s `Game::Actor`-or-`Game::Enemy` case): every real
call to `#apply_actor_meta` with a `:transparent` override in the saved
data crashes, meaning restoring actor metadata from a save file carrying a
transparency override was unconditionally broken under
`RPGMAKER_BC2CPP=1` before this fix landed.

The same general fix additionally closes, for free, `RPG2k::Scene::
ItemMenu#items`/`RPG2k::Scene::SkillMenu#skills` (each collides with
`Game::Party#items`/`Game::Actor#skills`, both real `attr_reader`s) and 13
further whole-program name collisions (`active`, `party`, `switches`,
`variables`, `windowskin`, `z`, and others) -- all confirmed to have zero
live effect today (every real call site either already resolves to the
correct class by construction, such as a self-call, or the two colliding
classes happen to share an identically-named and identically-typed backing
ivar), the same "confirmed sound today, latent risk for tomorrow" shape
already established elsewhere in this ADR (e.g. the `Game::Interpreter#
switches` gap the prior follow-up section documents) -- but now closed
structurally rather than merely by accident.

**The fix** (`tools/bc2cpp/bc2cpp.rb`'s `build_registry`): recognizes
`attr_reader`/`attr_writer`/`attr_accessor` sends as a third case alongside
the existing `private`/`protected`/`public` handling, reusing the same
backward-LOADSYM-argument-collection walk already established for
`private :a, :b, ...`'s own retroactive-visibility case. For each collected
name, registers a synthetic `MethodDef` (`irep: nil`, the same shape
`extract_native_method_names`'s own merge already uses for a native method
with no bytecode body to devirtualize into) under that class -- for
`attr_writer`/`attr_accessor`, also registers the `name=` setter. This can
only ever turn an unsound MONO into a correctly cautious POLY, never remove
a genuinely sound one: it only adds an entry for a name that really does
have another real definition somewhere in the closed world, and
`monomorphic_target` already refuses to devirtualize the moment
`@registry[name].size != 1`.

**Verified the fix actually changes the generated output**, not just that
it compiles: before the fix, `Game__Battle_critical__impl`'s `b.crit_chance`
read compiled straight through to `Game__Actor_crit_chance_impl` with no
`mrb_funcall` at all; after, the real generated body reads:
```
r4 = r1;
// POLY :crit_chance -- real dynamic dispatch, receiver's runtime class decides
r4 = mrb_funcall(M, r4, "crit_chance", 0);
```
-- correctly falling back to ordinary dynamic dispatch, exactly like
`:random`'s own call two lines above it in the same method.

**`RPG2k::Scene::EventResolver`** (`mruby-rpg2k/mrblib/scene/base.rb`, same
file, right below `MapWorld`/`VehicleWorld`) is the small helper that
resolves a Call Event's own command list, by common-event id
(`#common_event_commands`) or by map-event id/page
(`#map_event_commands`). 2 of its own 3 real bytecode-defined methods
compile clean: `#initialize` (`initialize common_by_id, map_events`, pure
mandatory arity, no super, no block) and `#common_event_commands` (a Hash
`#[]` read/memoizing Hash `#[]=` write via GETIDX/SETIDX, plus one real
POLY `.event` send that correctly stays ordinary `mrb_funcall` dispatch,
never devirtualized, since `:event` has other real definitions elsewhere
in the closed world). `#map_event_commands` is the one gap -- its own body
ends in a real `rescue StandardError` clause (RESCUE/RAISEIF/EXCEPT), the
same already-established out-of-scope shape as `MapWorld`'s/
`VehicleWorld`'s own `#play_sound`. Neither of this class's own two ivars
(`@common`, `@map_events`) ever gets embedded: both are real Hashes, a
type `IvarLayout`'s embedding lattice only ever models for Fixnum/Symbol --
confirmed directly against the real generated output, this class does not
appear in bc2cpp's own "classes needing `MRB_SET_INSTANCE_TT`" diagnostic.

**`Game::NumberInput`** (`mruby-rpg2k/mrblib/game.rb`) is the digit-cursor
input model backing the Input Number event command (a fixed count of 0..9
digit cells, a movable cursor, per-cell increment/decrement, and the
entered base-10 integer). 6 of its own 7 real bytecode-defined methods
compile clean: `#initialize`, `#digit`, `#inc`, `#dec`, `#left`, `#right`
(`#digits`/`#cursor` are `attr_reader`-generated, native, invisible to
bc2cpp the same way every other `attr_reader` in this codebase is).
`#value` is the one gap -- its own body ends in a real `@values.each { |d|
v = v * 10 + d }` block (BLOCK/SENDB), the same established out-of-scope
shape every other block-using method already documents. Despite
`#initialize` having pure mandatory arity, neither of this class's own two
Fixnum-shaped ivars (`@digits`, `@cursor`) actually gets embedded: both are
clamped/derived through a real conditional (`d = 1 if d < 1; d = MAX_DIGITS
if d > MAX_DIGITS`), and bc2cpp's own straight-line backward ivar-type scan
resolves the last write ahead of each SETIV to the `d = MAX_DIGITS`
branch's own GETCONST -- a constant lookup, never traced as a literal
fixnum value regardless of what `MAX_DIGITS` actually resolves to -- so
both conservatively resolve to UNKNOWN and stay on the ordinary dynamic
`iv_tbl`. Safe (a missed embedding opportunity, never an unsound one).
`@values` (a real Array) gets a devirtualization-only `CLASS_HINT`, never a
struct-field candidate.

**The dedicated bug-hunt pass** read all of `bc2cpp.rb` end to end looking
specifically for a third instance of the "compiles and links clean but
generates silently wrong code" bug shape (the two most severe bugs found
across this whole effort -- the keyword/splat argument-count mis-parse and
the bitwise/modulo operator-name character-class gap -- were both exactly
this shape). It cross-checked every SEND-name-extracting regex in
`bc2cpp.rb` against every real method name and call-site target actually
used project-wide, re-examined `IvarLayout.analyze`/`.join`'s type lattice
for another poisoning-style bug beyond the already-fixed UNKNOWN one,
re-examined `ArgTypes.analyze`'s call-site arg-count/type parsing for
another mis-parse beyond the already-fixed keyword/splat one, checked
`trace_new_target`'s `.new`-detection heuristic for a case where it could
resolve to the wrong target class, and checked the MONO/POLY
devirtualization registry for a category of native method invisible to
it. That last check is exactly where the `attr_reader`/`attr_writer`/
`attr_accessor` gap above turned up -- a prior round's own follow-up had
already found and documented that `attr_reader` is invisible to
`extract_native_method_names`'s own native-method-table scanner (checked
then only for `Game::State#switches`, and confirmed not currently
exploitable through *that* mechanism), but had not checked whether the
*same* invisibility also reaches `build_registry`'s own bytecode-only
MONO/POLY walk -- a related but distinct piece of this compiler, and the
one that turned out to be live. Beyond that, the pass also checked `alias`,
`define_method`, and module-`include`d methods for the same category of
gap and found no live instance of either: no `alias`- or
`define_method`-installed method anywhere in the closed world currently
collides with a same-named real bytecode `def` on a different class the
way `attr_reader`/`writer`/`accessor` did, and no `include`d module method
does either (checked directly against the real source, not assumed).
Every SEND-name-extracting regex it checked against the real project-wide
corpus of method names/call-site targets already matches correctly, no
second `IvarLayout`/`ArgTypes` mis-parse was found, and `trace_new_target`
was not shown a case where it picks the wrong class.

**Full-sweep re-check** (all thirty-five now-shipped targets, rebuilt with
the `attr_reader`/`writer`/`accessor` fix applied): every previously-
shipped class's own entry-point count matches exactly -- the same 33
counts this ADR's own prior follow-up already lists, unchanged; new:
`RPG2k::Scene::EventResolver` (2), `Game::NumberInput` (6). The fix only
ever narrows an existing MONO devirtualization to POLY dynamic dispatch,
never removes a compiled entry point or changes which methods compile at
all, so an unchanged entry-point count across every class is exactly the
expected outcome, not a sign the fix did nothing -- confirmed it did
something real by reading the actual generated body of
`Game__Battle_critical__impl` directly (see above): the `b.crit_chance`
call site itself changed from a direct call into
`Game__Actor_crit_chance_impl` to a real `mrb_funcall`.

**Verified for real:** the real, opt-in `RPGMAKER_BC2CPP=1` build succeeds
end to end (`EXIT: 0`), with **zero** compile errors, **zero**
`-Winfinite-recursion` warnings, and **zero** matches for the broken
empty-name `mrb_funcall(M, <reg>, "", ` shape. `nm -C` on the resulting
`libmruby.a` shows all 8 new entry points (2
`RPG2k__Scene__EventResolver_*_impl`, 6 `Game__NumberInput_*_impl`) present
and externally linked, neither class appearing in the embedding-struct
symbol set (no `_ivars`/`_free`/`_type` for either), with every
already-shipped class's own symbol count unchanged (`RPG2k::Scene::
VehicleWorld` still shows its 14-symbol embedding footprint, `Game::
TextReveal` still shows its 12-symbol footprint).

## Follow-up: RPG2k::Scene::GameOver, Game::Actors, and this compiler's fourth severe bug -- Struct.new(...) do...end blocks completely invisible to the registry

A twenty-fifth and twenty-sixth, independent round each add one more small
coverage target, plus a second dedicated bug-hunt pass run in parallel with
them. That pass found and fixed a fourth severe, live, already-shipped bug
-- once again in the MONO/POLY devirtualization registry, the same area
the immediately preceding follow-up's own fix touched.

**`RPG2k::Scene::GameOver`** (`mruby-rpg2k/mrblib/scene/game_over.rb`) is
the RPG2000 Game Over screen. Real source has 7 bytecode-defined methods,
not the 3 a first read of just `#initialize`/`#update`/`#dispose`
suggests -- `#gameover_bitmap`, `#play_gameover_bgm`,
`#gameover_bgm_override` and `#database_gameover_bgm` are all real,
private, bytecode-defined helpers too. 4 of the 7 compile clean, needing
no new opcode work at all: `#update`, `#dispose`, and the two private
helpers `#gameover_bgm_override`/`#database_gameover_bgm`. `#initialize`
(`initialize(parent, state = nil)`, one optional argument) has the
established non-mandatory-arity gap; `#gameover_bitmap` and
`#play_gameover_bgm` each end in a real `rescue StandardError => e`
clause. `#initialize` never compiling means `drop_unsafe_embeddings`
correctly refuses to embed any of this class's own ivars.

**`Game::Actors`** (`mruby-rpg2k/mrblib/game.rb` -- plural, the
actor-cache/lookup container, distinct from `Game::Actor` itself, already
a compiled owner) lazily builds and caches `Game::Actor` instances by
database id. 3 of its own 6 real bytecode-defined methods compile clean:
`#initialize(db)`, `#existing(id)` (a ternary plus one Hash `#[]` GETIDX
read), and `#known_invalid?(id)`. `#[]` ends in a real `rescue
RuntimeError => e` clause; `#all` ends in a genuine Ruby block
(`@all.keys.sort.map { |i| ... }`); `#each(&blk)` is a distinct gap from
either -- an explicit `&blk` block *parameter* (not a `do...end`/`{}`
block literal at a call site) trips this compiler's own ENTER-arity check
before the body is looked at at all, the same calling-convention gap
every non-mandatory-argument target elsewhere in this file already
documents, just via a block parameter instead of an optional/keyword/rest
one. None of this class's own three ivars (`@db`, `@all`, `@missing`)
ever gets embedded -- all three are opaque-reference/Hash-typed, a type
`IvarLayout`'s embedding lattice only ever models for Fixnum/Symbol.

**The bug:** `build_registry`'s bytecode walk recognizes `CLASS`/`MODULE`
(a real `class`/`module` body) and, as of the immediately preceding
follow-up, `attr_reader`/`attr_writer`/`attr_accessor` sends as ways a
class installs a method -- but `Struct.new(:a, :b, ...) do ... end`, a
third real, common way, was invisible in *two* distinct respects at once.
First, `Struct.new` is an ordinary method call (`SENDB`, since it takes a
block), not a `CLASS`/`MODULE` opcode, so nothing in the walk ever
recurses into the block's own body -- any real `def` written inside it
was never registered at all, not even as a same-name collision, simply
absent. Second, the plain member names Struct.new is given are real
reader+writer methods `Struct.new` installs natively (mruby's own
`struct.c`), never a bytecode `TDEF` either -- the same native-accessor
blind spot the `attr_reader`/`writer`/`accessor` fix closes, just for a
different installation mechanism entirely invisible to that fix.

**Confirmed live, not hypothetical, in two already-shipped, already-
registered compiled methods:** `Game::Battle::Combatant`
(`mruby-rpg2k/mrblib/game/battle.rb`) is `Struct.new(:name, ..., :actor,
:states, ..., :crit_chance, ...) do ... def state?(id); (states ||
[]).include?(id); end ... end` -- both `Combatant#state?` (a real `def`
inside the block) and `Combatant`'s own plain `actor` member reader
(installed natively by `Struct.new`) were invisible to the registry
before this fix. `Game::Actor#state?(state_id)` (`mruby-rpg2k/mrblib/
game.rb`, `return false if state_id.nil? || state_id == 0;
@states.include?(state_id)`) is the *only* bytecode-visible definition of
`:state?` anywhere else in the closed world; `RPG2k::Scene::EquipMenu
#actor` (`mruby-rpg2k/mrblib/scene/equip_menu.rb`) is the only bytecode-
visible definition of `:actor`. `Game::Battle#cure_state(target, sid)`'s
own real `return unless target.state?(sid)` (`target` a real `Combatant`
on every real call site, never a `Game::Actor`) devirtualized straight
into `Game__Actor_state__impl(M, target, sid)` -- whose own body reads
`mrb_iv_get(M, self, "@states")`, which returns `nil` on a real `Struct`
instance (`Struct` stores its members positionally, never via `iv_tbl`),
so the very next real send in that same body, `nil.include?(state_id)`,
is a guaranteed `NoMethodError` the moment any state is cured in battle.
Independently, `Game::Battle#combatant_permanent_states(target)`'s own
real `target.actor` (19 real call sites, `target` again always a
`Combatant`) devirtualized straight into `RPG2k__Scene__EquipMenu_actor_
impl(M, target)`, whose own body reads UI-menu-only ivars that don't
exist on a `Combatant` either. Both `Game::Battle#cure_state` and
`#combatant_permanent_states` are already registered and shipped
(`mruby-rpg2k-compiled/src/register.cxx`) -- meaning every state-cure in
a real compiled battle was broken before this fix landed, in a build
that compiled and linked clean with zero warnings.

**The fix** (`tools/bc2cpp/bc2cpp.rb`'s `build_registry`): a new `SENDB`
case recognizes a bare `Struct.new(...)` call (the receiver register's
own last write, walked backward, has to be a plain `GETCONST` naming
`Struct` exactly -- a computed or aliased Struct-like receiver is simply
not recognized, always safe, just a missed case). It registers each
member name's reader and writer as synthetic `MethodDef`s (`irep: nil`,
same shape the `attr_reader`/`writer`/`accessor` fix already uses), reads
the assigned constant name off a same-register `SETCONST` immediately
after (falling back to a synthetic placeholder owner name if the result
isn't immediately named this way, since registry soundness only needs
*a* distinct owner, not necessarily the *correct* one, to make
`monomorphic_target`'s own `defs.size == 1` check see more than one real
definition), and recurses this exact same walk into the block's own
child irep so a real `def` like `Combatant#state?` is registered as an
ordinary `MethodDef` with a real `irep`, exactly like any other class
body. Every check in the new case is a `next unless` guard that bails out
silently when an assumption doesn't hold, so the fix can only ever add
registry entries for names a real `Struct.new` call site really does
install -- never remove a sound entry, never register something under
the wrong class in a way that could turn a currently-correct
devirtualization unsound.

**Verified the fix actually changes the generated output** for both real
instances: `Game__Battle_cure_state_impl`'s `target.state?(sid)` now
reads `// POLY :state? -- real dynamic dispatch, receiver's runtime class
decides` / `mrb_funcall(M, r4, "state?", 1, r5)`; `Game__Battle_
combatant_permanent_states_impl`'s `target.actor` now reads `// POLY
:actor -- real dynamic dispatch...` / `mrb_funcall(M, r4, "actor", 0)`.

**Full-sweep re-check** (all thirty-seven now-shipped targets, rebuilt
with the Struct.new fix applied): every previously-shipped class's own
entry-point count matches exactly -- the same 35 counts this ADR's own
prior follow-ups already list, unchanged; new: `RPG2k::Scene::GameOver`
(4), `Game::Actors` (3). Exactly like the `attr_reader`/`writer`/
`accessor` fix, this one only ever narrows an existing MONO
devirtualization to POLY dynamic dispatch, never removes a compiled
entry point or changes which methods compile at all -- an unchanged
entry-point count across every class is the expected outcome.

**Verified for real:** the real, opt-in `RPGMAKER_BC2CPP=1` build
succeeds end to end (`EXIT: 0`), with **zero** compile errors, **zero**
`-Winfinite-recursion` warnings, and **zero** matches for the broken
empty-name `mrb_funcall(M, <reg>, "", ` shape across all three generated
files (`rpg2k_compiled_gen.cpp`, `lcf_compiled_gen.cpp`,
`rgss_compiled_gen.cpp`). `nm -C` on the resulting `libmruby.a` shows all
7 new entry points (4 `RPG2k__Scene__GameOver_*_impl`, 3
`Game__Actors_*_impl`) present and externally linked, neither class
appearing in the embedding-struct symbol set, with every already-shipped
class's own symbol count unchanged.

## Follow-up: Game::Rng

A twenty-seventh, independent round adds `Game::Rng`
(`mruby-rpg2k/mrblib/game.rb`) -- the engine's own seeded
linear-congruential PRNG (`@state = (@state * 75 + 74) % PERIOD`, a prime
modulus), used wherever the original RPG_RT's own randomness needs to
match byte-for-byte (enemy encounter rolls and the like; `Kernel#rand`
exists too, via mruby-random, but is unseeded). Pure coverage-expansion
work: no new opcode support was needed, and the round's own adversarial
re-check (re-running `report_annotation_candidates`, re-grepping the
real generated output for the empty-name `mrb_funcall` shape, and
re-reading `build_registry`'s own MONO/POLY walk against this class's
specific call shapes) found no new live `bc2cpp.rb` bug.

3 of its own 4 real bytecode-defined methods compile clean: `#next_int`
(a real `GETCONST` for `PERIOD` plus `MUL`/`ADDI` fastpaths, and a POLY
`%` send that correctly stays ordinary `mrb_funcall` dispatch -- `%` has
other real definitions project-wide) and `#random`/`#scaled`, each a
MONO self-call straight into `Game__Rng_next_int_impl` with no
`mrb_funcall` at all (`:next_int` has exactly one real bytecode
definition anywhere in the closed world). `:random` itself is POLY (3
defs: `Game::Rng`, `RPG2k::Scene::MapWorld`, `RPG2k::Scene::VehicleWorld`,
confirmed directly against the real registry dump) -- irrelevant to
registering `Game::Rng`'s own `#random` (POLY only affects whether some
*other* call site devirtualizes into it, never whether a class's own
methods can be compiled and registered), but real anyway: it means
`Game::Rng#random`'s own compiled body is now itself a real
devirtualization *target*, not just a source. `#scaled`'s own `next_int *
scale / PERIOD` additionally exercises a real `DIV`, which correctly
stays ordinary `mrb_funcall` dispatch too, per this compiler's own
established no-fastpath-for-`DIV` rule (real Ruby integer division floors
toward negative infinity, not C's truncating `/`). `#initialize`
(`initialize(seed = 1)`, one optional argument) is the one gap -- the
same established non-mandatory-arity shape as every other unembedded
target above, confirmed directly against the real diagnostic's own
`== skipped (unsupported, left on the interpreter) ==` list, not assumed.
`drop_unsafe_embeddings` correctly refuses to embed this class's own one
real ivar (`@state`, provably Fixnum): confirmed directly against the
real generated output, `Game::Rng` does not appear in bc2cpp's own
"classes needing `MRB_SET_INSTANCE_TT`" diagnostic, so no
`MRB_SET_INSTANCE_TT` call belongs in its own registration block, and
`@state` stays on the ordinary dynamic `iv_tbl` in every compiled method.
No bare `private`/`protected`/`public` anywhere in the real source, so
all three compiled methods are plain `mrb_define_method`; `#initialize`
itself is forced private by mruby's own interpreter regardless of source.

Cross-checked every one of the three registered methods against the real
diagnostic's own `== compiled entry points ==` listing one by one (not
just a summary count) before registering anything:
```
Game__Rng_next_int / Game__Rng_next_int_impl  (Game::Rng#next_int, arity 0)
Game__Rng_random / Game__Rng_random_impl  (Game::Rng#random, arity 1)
Game__Rng_scaled / Game__Rng_scaled_impl  (Game::Rng#scaled, arity 1)
```
None carry a `[private]`/`[protected]` annotation, matching the plain
`mrb_define_method` calls `register.cxx` uses. Grepped the freshly
generated `rpg2k_compiled_gen.cpp` for the empty-name
`mrb_funcall(M, <reg>, "", ` shape directly: zero matches, both in a
`Game::Rng`-only (`ONLY_OWNERS=Game::Rng`) run and in a full run with
every owner across all three compiled gems.

A real, positive synergy from whole-program devirtualization, found
while re-checking the full-owner output rather than the narrow
`Game::Rng`-only one: `RPG2k::Scene::VehicleWorld#random`'s own `@rng.
random(n)` (already shipped, `@rng` already `CLASS_HINT`-typed to
`Game::Rng`) now compiles to a real runtime-class-guarded direct call
into `Game__Rng_random_impl`, falling back to ordinary `mrb_funcall` only
if the guard fails, in place of the unconditional `mrb_funcall` it
compiled to before this round (`Game::Rng` was not yet an emitted owner,
so `compile_send`'s own owner-not-emitted guard kept it on the dynamic
path). No source or `bc2cpp.rb` change was needed for this -- it falls
straight out of adding `Game::Rng` to `ONLY_OWNERS`.

**Verified for real:** the real, opt-in `RPGMAKER_BC2CPP=1` build was
attempted end to end in a fresh worktree and hit several unrelated
environment-setup gaps before this round's own code was even reached,
each fixed in the environment (not in this round's diff) to make
progress: five further mruby submodules the host build actually needs
(`3rd/mruby-marshal`, `3rd/mruby-onig-regexp`, `3rd/mruby-stringio`,
`3rd/uni-algo`, `3rd/stb`) were uninitialized in the fresh worktree (a
bare `git submodule update --init 3rd/mruby` alone is not enough); the
`cp932_table`/`jis0208_table` env vars `mruby-lcf`'s/`mruby-rgss`'s own
codegen scripts read are not defaulted anywhere a raw `rake` invocation
sees (`scripts/native-build-without-nix.bash`'s own values, pointed at
this environment's pre-staged `.native-build-tables/` directory, unblock
it). With both fixed, the build reached and fully compiled
`mruby-lcf-compiled/src/register.cxx`, ran this round's own real
whole-program `bc2cpp.rb` diagnostic (the `== compiled entry points ==`
listing quoted above came from that real run, `MRBC` pointed at the
just-built real host `mrbc`), and printed **zero** compile errors so far
-- but then hit a genuine, out-of-scope environment gap this round did
not attempt to repair: `mruby-rgss/src/lib.cxx` needs a real, built
`lvgl.h`/linked LVGL library (`3rd/lvgl`, a large embedded-GUI submodule
normally built by this project's own CMake path, per this ADR's own
earlier note that LVGL is a real link-time dependency of `mruby-rgss`
even for a plain host build), which a raw `rake -f 3rd/mruby/Rakefile`
invocation has no step to build at all.

Verified the actual code correctness a different, still-rigorous way
given that gap: regenerated all three compiled gems' real output
(`rpg2k_compiled_gen.cpp`/`lcf_compiled_gen.cpp`/`rgss_compiled_gen.cpp`,
full `ONLY_OWNERS`/`OTHER_OWNERS`/`OTHER_DECLS_HEADER` wiring exactly
matching each `mrbgem.rake`) with the real host `mrbc`, then
`g++ -fsyntax-only -Wall -Wextra -Winfinite-recursion` each compiled
gem's real `register.cxx` against its own real generated file plus the
real mruby headers (`3rd/mruby/include`, the real generated
`mruby/presym/id.h`) -- register.cxx itself never includes RGSS/LVGL
headers directly, only mruby core ones, so this check needs no LVGL at
all. All three: **zero errors, zero `-Winfinite-recursion` warnings**
(the only warnings anywhere are pre-existing, unrelated
`-Wunused-but-set-variable` ones in already-shipped classes, e.g.
`RPG2k::Scene::SkillMenu`/`StatusMenu`/`Title`, not introduced by this
round). Re-confirmed the empty-name `mrb_funcall` grep against all three
full-owner generated files: zero matches. This does not confirm the
final *link* (blocked on LVGL, as above) but does confirm every
declaration this round's new code and its cross-gem devirtualization
target reference is type-correct and consistent with the real,
already-shipped classes around it -- left for a correctly-configured
checkout (with `3rd/lvgl` actually built) to confirm the final link and
runtime diff, the same "real bc2cpp.rb bugs found, if none say so
plainly" honesty this ADR's own every prior round already holds to. That
confirmation landed later in the same round, in the merge/integration
build below.

## Follow-up: Game::Weather, and this compiler's fifth severe bug -- `def self.x` singleton methods completely invisible to the registry

The same round also adds `Game::Weather` (`mruby-rpg2k/mrblib/game.rb`)
-- the current screen-weather effect state (rain/snow/fog/... type plus
a 0-10 strength). 4 of its own 5 real bytecode-defined methods compile
clean, needing no new opcode work at all: `#set` (plain SETIVs),
`#none?` (`@type == 0`), `#to_h` (a real Hash *literal*, checked
directly against the generated C++ -- `mrb_hash_new_capa(M, 2)` plus two
`mrb_hash_set` calls keyed by `mrb_symbol_value`, identical to
`Game::Picture`'s/`Game::Timer`'s own already-shipped `#to_h`), and
`#load_h(h)` (a Hash `#[]` GETIDX read plus a `||` default, the same
shape `Game::Screen`'s/`Game::Timer`'s own `#load_h` already compiles
clean against). `#initialize(type = 0, strength = 0)` (two optional
arguments) has the established non-mandatory-arity gap, so
`drop_unsafe_embeddings` correctly refuses to embed either of this
class's own two provably-Fixnum ivars (`@type`, `@strength`) --
confirmed directly against the real generated output, `Game::Weather`
does not appear in bc2cpp's own "classes needing `MRB_SET_INSTANCE_TT`"
diagnostic. `attr_reader :type, :strength` stay native/uncompiled --
confirmed live in the registry (`:type` shows `POLY`, 2 defs:
`Game::Weather`, `Game::Vehicle`, proving the `attr_reader` registry fix
from two rounds ago covers this class too).

The round's own dedicated bug-hunt pass (a third in a row, this time
finding a bug in a genuinely different mechanism than the previous two)
found and fixed a fifth severe, live, already-shipped bug in
`build_registry`: a real `def self.foo` (or `def SomeConst.foo`) never
compiles to the ordinary `TDEF` opcode this walk switches on at all --
mrbc's own codegen fuses `SCLASS`+`METHOD`+`DEF` into one distinct
`SDEF` opcode instead, installing the method onto the receiver's own
*singleton* class, a real, separate method table from `TDEF`'s own
target -- completely invisible to a registry that only ever walked
`TDEF`. The same "invisible to the bytecode-only registry" shape as the
`attr_reader`/`Struct.new` fixes already close, just for a third,
distinct installation mechanism (a real bytecode opcode this walk never
switched on at all, rather than a native method or one installed by
`Struct.new`).

**Confirmed live, not hypothetical, in already-shipped, already-compiled
code:** `Game.clamp(v, lo, hi)` (`def self.clamp`, `mruby-rpg2k/mrblib/
game.rb`) was invisible to the registry, leaving `RPG2k::Scene::MapViewer
#clamp` (a private 3-arg helper) as the *only* bytecode-visible
`:clamp` definition anywhere in the whole program. Every one of dozens
of already-compiled `Game.clamp(...)` call sites (across `Game::Actor`,
`Game::Screen`, `Game::Party`, `Game::Battle`, `Game::Transition`, and
others) devirtualized straight into `RPG2k__Scene__MapViewer_clamp_impl`,
passing the `Game` module object itself as `self`. This was harmless
*today* only by luck: confirmed directly against the real generated
`rpg2k_compiled_gen.cpp` that `RPG2k::Scene::MapViewer_clamp_impl`'s own
`self` parameter is copied into a register and never read again, so
both real `#clamp` bodies happen to be pure functions of their three
arguments. A related, unluckier collision was also found: `Game::
Interpreter#trans_to_opacity`'s own body is literally `Game.
trans_to_opacity(top_trans)` -- had `Game::Interpreter` ever joined a
compiled gem's `ONLY_OWNERS`, this would have compiled to a literal
unconditional self-call, infinite recursion, caught here only because
that class hasn't joined one yet.

**The fix**: register a synthetic `MethodDef` (`irep: nil`, mirroring
the existing `attr_reader`/native-method entries) for each `SDEF`, so a
same-named real `TDEF` elsewhere correctly counts as a second definition
and flips MONO to POLY -- the same guarantee every other synthetic-
`MethodDef` fix in this file already carries: this can only ever turn an
unsound MONO into a correctly cautious POLY, never remove a genuinely
sound one.

**Other angles investigated this round, no live bug found:** `IvarLayout`
cross-inheritance soundness (traced every real subclass pair in the
closed world -- every subclass's own `#initialize` calls `super`, an
unsupported opcode, so none currently embed; the one base class with
embeddable-looking ivars, `RPG2k::Scene::Base`, has only opaque object
references, so it never embeds either -- no live hazard exists today); a
second `compile_send` codegen bug (re-read end to end, found already
well-hardened); registry-build ordering (the registry is built once,
completely, before `ArgTypes`/`IvarLayout`/codegen ever run -- no
ordering hazard is structurally possible); and diamond-shaped dispatch
(`monomorphic_target` requires `defs.size == 1` by construction, so it
cannot "pick one of several POLY candidates").

**Two further structural gaps were found and confirmed NOT currently
exploitable**, left for a future round rather than fixed here to avoid
scope creep on this pass: methods defined inside `class << self ... end`
(`SCLASS`) are also invisible to the registry (e.g. `RGSS::Bitmap.
extensions`); and an empty `class`/`module` body emits no `EXEC`, so
`build_registry`'s own `pending_reg`/`pending_name` tracking never
resets and can leak into a later, unrelated `EXEC` (confirmed causing
`RGSS.asset_archive`/`asset_archive=` to be mislabeled under owner
`RGSS::Timeout`). Both observed instances today are `attr_accessor`-
synthetic entries with `irep: nil`, so neither is currently live, but
both are real gaps worth closing later.

**Full-sweep re-check** (all thirty-nine now-shipped targets, rebuilt
with the SDEF fix applied): every previously-shipped class's own
entry-point count matches exactly -- the same 37 counts this ADR's own
prior follow-ups already list, unchanged; new: `Game::Rng` (3),
`Game::Weather` (4).

**Verified for real**, completing the confirmation the `Game::Rng`
section above left open: the real, opt-in `RPGMAKER_BC2CPP=1` build
succeeds end to end (`EXIT: 0`), with **zero** compile errors, **zero**
`-Winfinite-recursion` warnings, and **zero** matches for the broken
empty-name `mrb_funcall(M, <reg>, "", ` shape. `nm -C` on the resulting
`libmruby.a` shows all 7 new entry points (3 `Game__Rng_*_impl`, 4
`Game__Weather_*_impl`) present and externally linked, neither class
appearing in the embedding-struct symbol set, with every already-shipped
class's own symbol count unchanged. Every real `Game.clamp(...)` call
site in the generated output now reads `// POLY :clamp -- real dynamic
dispatch, receiver's runtime class decides` / a real `mrb_funcall`,
confirming the SDEF fix actually changes generated code, not just
theory.

## Follow-up: Game::Troop, and a checked-but-not-live `&:symbol` block-pass shape

A twenty-ninth, independent round adds `Game::Troop`
(`mruby-rpg2k/mrblib/game/battle_support.rb`) -- the enemy-party
container for a battle (a group of `Game::Enemy` instances built from a
database Troop row). Only 1 of its own 7 real bytecode-defined methods
compiles clean, needing no new opcode work at all and finding no live
`bc2cpp.rb` bug: `#member` (`def member(db, m); Enemy.new(db, m.enemy_id,
m.x, m.y, m.invisible); end`, a plain 4-argument constructor call, no
arithmetic, no block).

`#initialize` (`db, id, rng = nil`, one optional argument) has the same
established non-mandatory-arity gap as every other unembedded target
above, so `drop_unsafe_embeddings` correctly refuses to embed any of this
class's own four ivars (`@id`/`@name`/`@members`/`@pages`) -- confirmed
directly against the real generated output, `Game::Troop` does not
appear in bc2cpp's own "classes needing `MRB_SET_INSTANCE_TT`"
diagnostic. `#total_exp`/`#total_gold` (`live_members.reduce(0) { |s, e|
s + e.exp/e.gold }`) and `#drops` (`live_members.each_with_object([]) do
|e, out| ... end`) each end in a genuine Ruby block (`BLOCK`/`SENDB`),
the same established out-of-scope shape every other block-using method
in this file already documents. `#apply_appear_randomly` ends in two
more real blocks (`@members.count { |m| ... }`, `@members.each do |m|
... end`).

`#live_members` (`@members.reject(&:hidden)`) was checked specifically
for whether the `&:symbol` block-pass shorthand might be a distinct,
narrower shape this compiler already handles, rather than assumed either
way: confirmed directly against the real `mrbc -v` disassembly, `&:hidden`
compiles to a bare `LOADSYM R3 :hidden` feeding `SENDB R2 :reject n=0`,
with **no** preceding `BLOCK` opcode at all -- no closure needs creating
for a Symbol-to-proc block-pass, unlike a real `{ }`/`do...end` block
literal, which always emits `BLOCK` immediately before its own `SENDB`.
This is still the exact same unmodeled `SENDB` opcode `compile_insn` has
never had a case for, though, just reached a second, narrower way --
confirmed against the real generated `#error unhandled opcode SENDB`
line for this method, not assumed from the disassembly alone. Not a new
gap, and not something worth adding `compile_insn` support for on its
own: `SENDB`'s own block argument would still need translating to a real
call into whatever the block turns out to be (a symbol here, an
arbitrary closure in the general case), the same underlying
out-of-scope problem either way.

`#member` is `private` (a bare `private` mid-class-body, in effect
through the end of the class, also covering `#live_members`/
`#apply_appear_randomly`), so it needs `mrb_define_private_method`, not
`mrb_define_method` -- confirmed directly against the real diagnostic's
own `== compiled entry points ==` listing, which flags it accordingly,
not assumed from the source alone.

**Verified for real:** the actual `build_config.rb` + `rake` pipeline was
run end to end in this environment; it reached and fully regenerated
`rpg2k_compiled_gen.cpp` (confirmed containing `Game__Troop_member_impl`/
`Game__Troop_member`) before hitting the same pre-existing, out-of-scope
LVGL gap this ADR's own `Game::Rng` follow-up already documents
(`mruby-rgss/src/lib.cxx` needs a real, built `lvgl.h`, which a raw `rake
-f 3rd/mruby/Rakefile` invocation has no step to build). Verified
correctness the same alternate, still-rigorous way that round used:
`g++ -fsyntax-only -Wall -Wextra -Winfinite-recursion` against the real
regenerated `register.cxx` plus its own real generated file and the real
mruby headers -- **zero errors, zero `-Winfinite-recursion` warnings**
(only the same pre-existing, unrelated `-Wunused-but-set-variable`/
`-Wunused-parameter` warnings already present in already-shipped
classes). Also compiled `register.cxx` to a real object file and
confirmed with `nm -C`: `Game__Troop_member_impl` is present and
externally linked (`T`), its `mrb_get_args` wrapper `Game__Troop_member`
correctly stays local (`t`), and neither appears in any embedding-struct
symbol set. Grepped the freshly regenerated full-owner
`rpg2k_compiled_gen.cpp` for the empty-name `mrb_funcall(M, <reg>, "", `
shape directly: zero matches. Cross-checked the real diagnostic's own
`== compiled entry points ==` listing for this class one by one (not
just a summary count) before registering anything -- exactly one line,
`Game__Troop_member / Game__Troop_member_impl (Game::Troop#member,
arity 2) [private -- use mrb_define_private_method, not
mrb_define_method]` -- matching what's actually registered below.

## Follow-up: Game::Vehicle, and this compiler's sixth severe bug -- `class << self` singleton-class bodies (and a stale-registration leak past an empty class body) invisible to the registry

The same round also adds `Game::Vehicle` (`mruby-rpg2k/mrblib/game.rb`)
-- a boat/ship/airship's saved location (map id, position, facing,
on-map graphic), plain data rather than a `Game::Character`. 4 of its
own 5 real bytecode-defined methods compile clean, needing zero
`bc2cpp.rb` changes: `#placed?` (a plain `@map_id > 0`), `#to_h` (a real
Hash literal, the same `mrb_hash_new_capa`/`mrb_hash_set` shape
`Game::Picture`'s/`Game::Timer`'s/`Game::Weather`'s own `#to_h` already
ship), `#load_h` (a Hash `#[]` GETIDX read plus a `||` default per
field), and `#load_movable` (the same GETIDX/`||`-default shape as
`#load_h`, plus one real `EventGraphic.numpad_direction(m[:direction])`
call). `:numpad_direction` is MONO in the whole-program registry
(`Game::EventGraphic`'s own real `def self.numpad_direction`, an `SDEF`
singleton method with owner `"Game::EventGraphic.singleton"`) but
correctly stays ordinary `mrb_funcall` dispatch regardless: that
synthetic `.singleton`-suffixed owner name never matches this run's own
plain-class-name `ONLY_OWNERS`/`OTHER_OWNERS`, so `compile_send`'s
existing owner-not-emitted guard correctly falls back rather than
referencing a function this run never emits. `#initialize(type, map_id
= 0, x = 0, y = 0, direction = 2)` is the one gap -- four optional
arguments, the established non-mandatory-arity shape -- so
`drop_unsafe_embeddings` correctly refuses to embed any of this class's
own four provably-Fixnum ivars despite the raw `IvarLayout` analysis
reporting all four as EMBED-eligible.

The round's own dedicated bug-fix pass had a known starting point this
time: the immediately preceding round's own bug-hunt pass had already
found and confirmed two real structural gaps in `build_registry` but
deliberately left them unfixed to avoid scope creep on that pass. This
round actually fixes both, closing a sixth severe, live,
already-shipped bug.

**Gap A: `class << self ... end` (or `class << SomeConst ... end`)
bodies are completely invisible to the registry.** A real `def self.foo`
compiles to the fused `SDEF` opcode (already fixed two rounds ago), but
`class << self; def foo; ...; end; end` is a different, older shape
entirely: `SCLASS` opens the receiver's own singleton class as a body of
its own, containing ordinary `TDEF`s -- exactly like a `CLASS`/`MODULE`
body, just reached via this distinct opcode, and previously invisible
because nothing recursed into an `SCLASS`-opened body the way `EXEC`
already does for a `CLASS`/`MODULE`-opened one. **Confirmed live, not
hypothetical:** grepping the whole closed world found 8 real instances,
every one in `mruby-rgss/mrblib/{lib.rb,error_report.rb}` --
`RGSS::Bitmap.extensions`, several of `RGSS::Font`'s own defaults, over
twenty of `RGSS::Audio`'s own methods (`bgm_play`, `resolve`, ...),
several of `RGSS::Graphics`'s own (`resize_screen`, `wait`, ...),
`RGSS::ErrorReport.lines`/`.last_location`, and `RGSS.asset_archive`.
Before this fix, a real registry dump showed every one of these names
completely absent -- not even a synthetic entry, unlike the
`attr_reader`/`SDEF` fixes' own synthetic-only approach, since an
`SCLASS` body can hold arbitrarily many real `def`s (`RGSS::Audio`'s
own alone defines over twenty) and genuinely needs the same real
recursion `CLASS`/`MODULE` already get, not just a placeholder.

**Gap B: an empty `class`/`module` body can leak stale
`pending_reg`/`pending_name` tracking into a later, unrelated `EXEC`.**
`build_registry`'s `CLASS`/`MODULE` (and now `SCLASS`) case sets
`pending_reg`/`pending_name`, expecting the very next relevant `EXEC` on
that same register to be the one that opens this construct's own body --
but a real empty class body (`class Timeout < StandardError; end`,
`mruby-rgss/mrblib/lib.rb`) emits NO `EXEC` at all for its own (empty)
body, since mrbc doesn't bother emitting a trivial always-empty
child-irep call. That left `pending_reg`/`pending_name` sitting stale
until *whatever* later instruction happened to reuse the same register --
however far away, however unrelated. **Confirmed live:** the very next
construct in the real source, `class << self; attr_accessor
:asset_archive; end`, reuses that same register for its own `SCLASS`,
so `RGSS.asset_archive`/`asset_archive=` registered under owner
`RGSS::Timeout` instead of the real receiver, `RGSS`.

**The fix** (one mechanism closes both gaps): `SCLASS` now sets the
same `pending_reg`/`pending_name` tracking `CLASS`/`MODULE` already use
-- the receiver is resolved by walking backward to the register's own
last write, trusting only a bare `LOADSELF` (`class << self`, self at
that point being the innermost enclosing namespace, the same fact
`SDEF`'s own fix already relies on) or a `GETCONST` naming a specific
constant (`class << SomeConst`); anything else is simply not recognized,
always safe, just a missed case. The registered owner is a distinct
`"X.singleton"` pseudo-owner (the same suffix `SDEF`'s own fix already
uses), which can never collide with or be selected by `ONLY_OWNERS`
(real Ruby constant paths only). Separately, a new `pending_idx` now
requires the matching `EXEC` to land on the *exact* next instruction
index, not merely the same register at any later point -- verified this
adjacency holds for every real `CLASS`/`MODULE`/`SCLASS`+`EXEC` pair in
the whole closed world's own disassembly, so this closes the leak
structurally rather than by luck, with no risk of breaking any
already-correct pairing.

**A further, related, but explicitly out-of-scope finding** was surfaced
while fixing the above and left undone to avoid scope creep on this
pass: `codegen_def`/`codegen_defs` fall back to an unfused
`TCLASS`/`SCLASS`+`METHOD`+`DEF` instruction sequence -- invisible to
this registry the same way `SDEF` used to be -- once a class body's own
child-irep index exceeds `0xff`. Confirmed real in already-shipped
`RPG2k::Scene::Map` (`#toned?`, `def self.tone_channel`); not currently
exploitable (`RPG2k::Scene::Map` is not yet a compiled owner), but a
real gap worth closing before that class ever joins one.

**Verification:** a full before/after registry diff across the whole
closed world shows every change from the fix is either a new
`"X.singleton"` pseudo-owner entry (never colliding with a real
`ONLY_OWNERS` class) or the `RGSS::Timeout` → `RGSS.singleton`
correction -- zero existing real owner's entries changed, so no
already-shipped class's own compiled entry-point count moves at all.

**Full-sweep re-check** (all forty-three now-shipped targets across all
three compiled gems, rebuilt with both this round's coverage and the
`SCLASS`/empty-body fix applied): every previously-shipped class's own
entry-point count matches exactly, `RGSS::Sprite` included (still 17,
confirming the registry fix changed zero already-correct entries); new:
`Game::Vehicle` (4).

**Verified for real:** the real, opt-in `RPGMAKER_BC2CPP=1` build
succeeds end to end (`EXIT: 0`), with **zero** compile errors, **zero**
`-Winfinite-recursion` warnings, and **zero** matches for the broken
empty-name `mrb_funcall(M, <reg>, "", ` shape across all three generated
files (`rpg2k_compiled_gen.cpp`, `lcf_compiled_gen.cpp`,
`rgss_compiled_gen.cpp`). `nm -C` on the resulting `libmruby.a` shows
the 4 new `Game__Vehicle_*_impl` entry points present and externally
linked, no pseudo-owner (`.singleton`-suffixed) symbol ever linked
anywhere, and every already-shipped class's own symbol count unchanged.

## Follow-up: Game::Enemy, and a confirmed-but-not-currently-live splat-encoded attr_reader registry gap

A thirtieth, independent round adds `Game::Enemy`
(`mruby-rpg2k/mrblib/game/battle_support.rb`) -- a single enemy combatant
built from a database Troop-member row (`Game::Troop#member`, this ADR's
own immediately preceding follow-up, constructs one per troop member).
3 of its own 4 real bytecode-defined methods compile clean, needing zero
`bc2cpp.rb` changes: `#attack_hit_rate` (`@miss ? 70 : 90`, a plain GETIV
plus JMPIF-based ternary), `#dead?` (`@hp <= 0`, the fixnum-fastpath LE
this compiler already has), and `#reseed_rewards` (`@exp = into.exp;
@gold = into.gold; @drop_id = into.drop_id; @drop_prob = into.drop_prob`,
four plain SETIVs fed by four real POLY sends that correctly stay
ordinary `mrb_funcall` dispatch -- confirmed directly against the real
generated output). `#initialize(db, id, x = 0, y = 0, hidden = false)`
(three optional arguments) is the one gap -- the same established
non-mandatory-arity shape as every other unembedded target above, so
`drop_unsafe_embeddings` correctly refuses to embed any of this class's
own thirteen provably-Fixnum ivars (`@max_hp`, `@max_sp`, `@atk`, `@def`,
`@spi`, `@agi`, `@x`, `@y`, `@hp`, `@sp`, `@flying_phase`,
`@crit_chance`, `@battler_hue`) despite the raw `IvarLayout` analysis
reporting all thirteen as EMBED-eligible -- confirmed directly against
the real generated output: `Game::Enemy` does not appear in bc2cpp's own
"classes needing `MRB_SET_INSTANCE_TT`" diagnostic, and every compiled
method here uses plain `mrb_iv_get`/`mrb_iv_set`, never `DATA_PTR(self)`.

**A real, confirmed-but-not-currently-live registry gap**, found by this
round's own step 5 discipline -- cross-checking every one of
`#reseed_rewards`'s own four POLY sends individually against the real
registry dump before registering anything, rather than trusting the
summary count. `Game::Enemy`'s own large `attr_reader :id, :name,
:battler_name, :max_hp, :max_sp, :atk, :def, :spi, :agi, :exp, :gold, :x,
:y, :drop_id, :drop_prob` (15 Symbol arguments in one call,
`mrblib/game/battle_support.rb:1043-1044`) compiles to `SSEND R1
:attr_reader n=*` in the real disassembly -- mrbc's own CALL_MAXARGS
splat encoding, used once a call's direct-encodable argument-count nibble
would overflow. Confirmed the exact boundary directly rather than
guessing: the only other attr_reader call project-wide that comes close
(`Game::Interpreter#initialize`'s own 14-Symbol `attr_reader :wait_kind,
...`) encodes fine as a literal `n=14`; Enemy's 15th argument is what
tips it over into `n=*`. `build_registry`'s own attr_reader/writer/
accessor fix (two rounds ago, this ADR's own EventResolver/NumberInput
follow-up) parses this same call site's own argument count with
`insn.args[/n=(\d+)/, 1].to_i` -- against the literal text `*` (not a
digit string), the regex match returns `nil`, and `nil.to_i` is `0` in
Ruby, silently -- so `collect_loadsym_names` (bounded by `n`) collects
zero names, and none of these 15 real Enemy accessor names ever gets a
synthetic registry entry for `Game::Enemy` at all, the exact same
"invisible to the registry" shape the original attr_reader fix closed,
just reopened for this one wider-than-14-argument call shape it didn't
anticipate.

Checked every one of the 15 names individually against the real registry
dump before concluding this is safe today, not assumed safe by analogy:
`:id`/`:name`/`:max_hp`/`:atk`/`:def`/`:agi`/`:exp`/`:x`/`:y` are all
already POLY from other real definitions (irrelevant either way -- POLY
already means ordinary dynamic dispatch); `:max_sp`/`:drop_id`/
`:drop_prob` have zero other definitions anywhere in the closed world
(nothing to unsoundly devirtualize into regardless); and the three that
do show a colliding single ("MONO") definition elsewhere --
`:battler_name`/`:spi` (`Game::Battle::Combatant`, a `Struct.new` member)
and `:gold` (`Game::Party`, itself only an `attr_reader`) -- are each
*also* synthetic (`irep: nil`) on that other side, and
`monomorphic_target` already refuses to devirtualize into any target
whose own `irep` is `nil` regardless of `defs.size` (`return nil unless
defs.first.irep`, this compiler's own long-standing guard for exactly
this "native/synthetic definition, no real body to call into" case).
Confirmed directly against the real generated output too: `Game::Enemy#
reseed_rewards`'s own four sends (`into.exp`/`into.gold`/`into.drop_id`/
`into.drop_prob`) all correctly emit `// POLY :<name> -- real dynamic
dispatch...` plus a real `mrb_funcall`, never an unsound direct call.
So this gap can only ever turn an already-safe call into a
differently-labeled-but-still-safe one, for every real name this
specific 15-argument call installs, today. Not fixed in this round to
avoid scope creep (`Game::Enemy`'s own three target methods above compile
fully clean without it, and the fix itself -- handling mrbc's splat
argument-count encoding generally, not just for this one call shape --
is a real, separate piece of work) -- left as a documented,
confirmed-safe-for-now structural gap for a future round, the same
"found, not currently exploitable" bucket as this ADR's own
unfused-SDEF-at-large-class-body finding two rounds up.

**Full-sweep re-check** (all forty-four now-shipped targets across all
three compiled gems, with zero `bc2cpp.rb` changes this round): every
previously-shipped class's own entry-point count matches exactly, and a
real before/after diff of the whole-program `== compiled entry points ==`
listing (`ONLY_OWNERS` with and without `Game::Enemy` added, everything
else identical) shows exactly three added lines and zero changed or
removed ones -- `Game__Enemy_dead_`/`Game__Enemy_attack_hit_rate`/
`Game__Enemy_reseed_rewards`, matching what's actually registered below.

**Verified for real:** built the real host `mrbc` from this environment's
own `3rd/mruby` submodule and ran `tools/bc2cpp/bc2cpp.rb` directly
(`ONLY_OWNERS`/`OTHER_OWNERS`/`NATIVE_SRCS` computed exactly the way
`mruby-rpg2k-compiled/mrbgem.rake` does, `SKIP_UNSUPPORTED=1`) against
the whole `mruby-rpg2k`+`mruby-lcf`+`mruby-rgss` closed world. Grepped
the real generated `rpg2k_compiled_gen.cpp` for the broken empty-name
`mrb_funcall(M, <reg>, "", ` shape: zero matches. `g++ -std=c++17 -Wall
-Wextra -Winfinite-recursion -fsyntax-only` against the real
`register.cxx` plus this real generated file and the real mruby headers:
**zero errors, zero `-Winfinite-recursion` warnings** (only the same
pre-existing, unrelated `-Wunused-but-set-variable` warnings already
present in already-shipped classes, `Game::Enemy`'s own three new
methods included -- each only from the same harmless unread-`self`-copy
shape every other compiled method here already has). Compiled
`register.cxx` to a real object file and confirmed with `nm -C`:
`Game__Enemy_dead__impl`/`Game__Enemy_attack_hit_rate_impl`/
`Game__Enemy_reseed_rewards_impl` are present and externally linked
(`T`), their `mrb_get_args` wrapper functions correctly stay local (`t`),
and `Game::Enemy` appears in no embedding-struct symbol set at all,
confirming step 6 directly rather than assuming it: no
`Game__Enemy_ivars` struct, no `MRB_SET_INSTANCE_TT` call, and every
compiled method reads/writes ivars through the ordinary dynamic
`iv_tbl`. This environment's own real, opt-in
`RPGMAKER_BC2CPP=1` + `rake -f 3rd/mruby/Rakefile` pipeline was not run
end to end this round: the fresh worktree's `3rd/mruby`,
`3rd/mruby-marshal`, `3rd/mruby-onig-regexp`, `3rd/mruby-stringio`,
`3rd/uni-algo`, and `3rd/stb` submodules were uninitialized (the same
gap this ADR's own `Game::Rng` follow-up already documents hitting), and
the shared host disk this session ran on hit a genuine, transient
0-bytes-free condition partway through initializing them -- recovered on
its own, but the environment fix was kept out of this round's own diff,
matching every prior round's own practice, and the real final-link
`mruby-rgss`/LVGL gap this ADR's own `Game::Rng` and `Game::Troop`
follow-ups already document was never reached this round either. The
`g++ -fsyntax-only`-plus-`nm` check above is the same "real, still-
rigorous" fallback those two rounds already used for the identical
reason.

## Follow-up: RPG2k3::Scene::Battle, and this compiler's seventh severe bug -- the unfused `TCLASS`/`SCLASS`+`METHOD`+`DEF` opcode sequence for large class bodies

The same round also adds `RPG2k3::Scene::Battle`
(`mruby-rpg2k/mrblib/scene/battle_rpg2k3.rb`) -- the real subclass
(`class Battle < RPG2k::Scene::Battle`, a distinct top-level namespace
from `RPG2k`, not the base UI battle scene itself, which is not a
compiled owner) adding RPG2003's active-time-battle (ATB) gauge
behavior. 7 of its own 15 real bytecode-defined methods compile clean,
needing no new opcode work at all: `#active_atb?`, `#atb_accumulating?`
(a Hash `#[]` GETIDX read, a MONO self-call into `#active_atb?`, and a
POLY `Array#include?` send against the frozen `ATB_MENU_PHASES`
class-constant array literal), `#gauge_battle?`, `#drive_battle_atb`
(MONO self-calls into `#controllable?`/`#start_gauge_action`),
`#start_gauge_action`, `#enter_atb_phase` (a MONO self-call into
`#drive_battle_atb`), and `#controllable?`. The other 8 (`#update`,
`#drive_battle_command`, `#enter_command_phase`, `#open_battle_options`,
`#advance_actor`, `#prev_commandable_actor_index`,
`#finish_round_animation`, `#interrupting_ready_combatant`) each hit a
bare `super` (`OP_SUPER`) and/or a genuine Ruby block, both
already-established out-of-scope shapes. Has no `#initialize` of its
own (inherits the base class's), so there is no non-mandatory-arity gap
to worry about, but also nothing to embed: confirmed directly against
the real generated output, this class never appears in bc2cpp's own
"classes needing `MRB_SET_INSTANCE_TT`" diagnostic (it never `SETIV`s
at all in any of its own methods -- every `@ui`/`@state` access here is
a Hash `#[]`/`#[]=` read or write, not a direct instance-variable
assignment).

The round's own dedicated bug-fix pass had a known starting point,
same as the immediately preceding round: the previous round's own
bug-fix pass, while fixing the `SCLASS`/empty-class-body registry gaps,
surfaced a further, related, but explicitly out-of-scope finding it
deliberately left unfixed: `mrbc`'s own `codegen_def`/`codegen_defs`
(`mrbgems/mruby-compiler/core/codegen.c`) fall back to an UNFUSED
`TCLASS`/`SCLASS`+`METHOD`+`DEF` instruction sequence -- instead of the
single fused `TDEF`/`SDEF` opcode the registry already recognized --
whenever a class body's own child-irep index exceeds `0xff` (255), i.e.
once a class/module body already contains more than 255 real
method/block child ireps. That round confirmed this real, live, in
already-shipped source: `RPG2k::Scene::Map#toned?` and `def
self.tone_channel` (a real singleton method) both use this unfused
shape, invisible to the registry the same way `SDEF` used to be before
an earlier round fixed the fused case. `RPG2k::Scene::Map` was not a
compiled owner at the time, so it was confirmed not yet exploitable --
but real and general, not specific to that one class. This round
actually fixes it, closing a seventh severe bug.

**Confirmed with real bytecode disassembly**, not just the description
above: `RPG2k::Scene::Map`'s own real `mrbc -v` disassembly shows,
for the ordinary instance method (`def toned?`):
```
TCLASS  R1
EXT2
METHOD  R2      I[380]
EXT2
DEF     R1      :toned?   (R2)
```
and, for the singleton method (`def self.tone_channel`):
```
LOADSELF R1     (R0)
SCLASS   R1
EXT2
METHOD   R2     I[379]
EXT2
DEF      R1     :tone_channel  (R2)
```
Real mrbc disassembly can interpose an `OP_EXT1`/`EXT2`/`EXT3`
pseudo-instruction between two instructions `codegen.c` emits
back-to-back with no logical gap -- each widens the *immediately
following* real instruction's own operand width, and is guaranteed to
appear here since the unfused path's own `METHOD` operand (a child-irep
index > `0xff`, by construction of reaching this path at all) always
needs one. Every other adjacency-based backward scan in this file had
gotten away with a plain `idx-1`/`idx-2` check only because none of
their own real, closed-world instances happened to need one -- this is
the first fix in this file that genuinely can't.

**The fix**: a new `when 'DEF'` case recognizes the real `METHOD`+`DEF`
opcode pair (walking back past any number of `EXT1`/`EXT2`/`EXT3`
pseudo-instructions to find the real opcode underneath, via a new
`skip_ext_back` helper), verifies the register alignment
`codegen_def`'s/`codegen_sdef`'s own unfused branch always emits
(opener at `R<n>`, `METHOD` at `R<n+1>`, `DEF` back at `R<n>`
referencing `(R<n+1>)`) rather than trusting adjacency alone, and then
registers the method exactly the way the fused case would have: as an
ordinary walkable `MethodDef` with a real `irep` for an instance method
(the `TCLASS` case), or the same `"X.singleton"` pseudo-owner the
`SDEF` fix already established for a singleton method (the `SCLASS`
case) -- except this time there IS a real child irep to compile, so
it's a real entry, not a synthetic placeholder. The receiver-resolution
backward scan the `SCLASS`-opened-body fix already has, and the
builtin-private-name visibility special case the `TDEF` case already
has, were both extracted into small shared helpers
(`resolve_singleton_receiver`, `resolve_def_visibility`) so this new
case reuses them exactly rather than duplicating the logic -- a pure
refactor of the already-shipped code, verified behavior-preserving by a
direct byte-for-byte diff against the pre-refactor source before this
round started.

**Verified the fix actually changes the registry, not just in theory**:
the real diagnostic's own registry dump now shows `:tone_channel` as
`MONO (1 def: RPG2k::Scene::Map.singleton)` and `:toned?` as `MONO (1
def: RPG2k::Scene::Map)` -- both real, walkable entries, exactly as
intended, where before this fix neither appeared in the registry at
all.

**Full-sweep re-check** (all forty-five now-shipped targets across all
three compiled gems, rebuilt with both this round's coverage and the
unfused-`DEF` fix applied): every previously-shipped class's own
entry-point count matches exactly, `RGSS::Sprite` and every `LCF::*`
class included, unchanged; new: `Game::Enemy` (3), `RPG2k3::Scene::Battle`
(7).

**Verified for real:** the real, opt-in `RPGMAKER_BC2CPP=1` build
succeeds end to end (`EXIT: 0`), with **zero** compile errors, **zero**
`-Winfinite-recursion` warnings, and **zero** matches for the broken
empty-name `mrb_funcall(M, <reg>, "", ` shape across all three
generated files (`rpg2k_compiled_gen.cpp`, `lcf_compiled_gen.cpp`,
`rgss_compiled_gen.cpp`). `nm -C` on the resulting `libmruby.a` shows
the 3 new `Game__Enemy_*_impl` and 7 new `RPG2k3__Scene__Battle_*_impl`
entry points present and externally linked, no pseudo-owner
(`.singleton`-suffixed) symbol ever linked anywhere, and every
already-shipped class's own symbol count unchanged.

## Follow-up: LCF::MoveCommand, mruby-lcf-compiled's first ivar-embedding target

A thirtieth, independent round adds `LCF::MoveCommand`
(`mruby-lcf/mrblib/lcf.rb`) to `mruby-lcf-compiled` -- the first new
owner that gem has gained since its original five `LCF::File`-family
classes. One decoded RPG2000 move-route command: a command id plus the
optional string/integer parameters a handful of move-route sub-commands
carry (switch on/off, change graphic, play sound). `attr_reader
:command_id, :parameter_string, :parameter_a, :parameter_b,
:parameter_c` stays native/uncompiled, as always -- there is no other
real bytecode-defined method on this class at all, so `#initialize` is
this class's only registered method.

`#initialize(command_id, string, a, b, c)` already carried a real
`# bc2cpp: (fixnum, , fixnum, fixnum, fixnum)` magic-comment annotation
from several follow-ups up (applied alongside `LCF::EventCommand#
initialize`'s own, neither wired up as a compiled owner at the time),
but this round confirmed everything for real against the actual
diagnostic rather than trusting the comment: the real `== compiled
entry points ==` listing shows exactly one line for this class,
`LCF__MoveCommand_initialize / LCF__MoveCommand_initialize_impl
(LCF::MoveCommand#initialize, arity 5) [private -- use
mrb_define_private_method, not mrb_define_method]` -- 5 purely
mandatory arguments, no `super`, no block, needing zero new
`bc2cpp.rb` opcode work and finding zero live `bc2cpp.rb` bugs.

`LCF::MoveCommand` appears in bc2cpp's own "classes needing
`MRB_SET_INSTANCE_TT`" diagnostic, and the real generated
`#initialize` body really does call `mrb_data_init` before any other
statement (guarded the same way every other embedded ivar write
already is -- a real `mrb_integer_p` check + `mrb_raise` on a
non-Integer value, never silent corruption). `@command_id`,
`@parameter_a`, `@parameter_b` and `@parameter_c` (all provably
Fixnum, matching the annotation) are real fields on a new
`LCF__MoveCommand_ivars` RData struct -- confirmed directly against
the generated code: `EMBED LCF::MoveCommand#@command_id (fixnum)` and
the same for the other three. `@parameter_string` (a String, not
Fixnum/Symbol) correctly stays off that struct despite embedding
alongside three ivars that do: the generated body writes it with a
plain `mrb_iv_set(M, self, mrb_intern_cstr(M, "@parameter_string"),
r2)`, the ordinary dynamic-`iv_tbl` path, mixed safely with the four
embedded fields on the very same object -- the same mixed-embedding
shape `Game::Screen`/`Game::Transition`/`Game::State`/`Game::Map`/
`Game::ChipSet` already established. `report_annotation_candidates`'s
own diagnostic confirms this wasn't guesswork: `CANDIDATE
LCF::MoveCommand#initialize, arg 2/5 -> @parameter_string` still
appears (the position is a real opaque-argument-to-ivar candidate this
compiler's analysis would consider), but the existing annotation's
blank second-position token (`(fixnum, , fixnum, fixnum, fixnum)`)
correctly asserts no claim there, so it stays `UNKNOWN` and unembedded.

`:command_id`/`:parameter_a`/`:parameter_b`/`:parameter_c`/
`:parameter_string` are all POLY in the whole-program registry (2 defs
each: this class and a real, separate `Game::MoveCommand`,
`mruby-rpg2k/mrblib/game.rb`, confirmed by grepping the whole closed
world for `class MoveCommand` and finding two distinct classes in two
different modules) -- correctly has no bearing on registering this
class's own method (POLY only affects whether some *other* compiled
call site could devirtualize into one of these names, never whether a
class's own methods can be registered), and neither compiled gem's own
generated output devirtualizes into any of them today. `:initialize`
itself is POLY too (62 real definitions across the whole closed
world), same as always -- moot, since `#initialize` is forced private
by mruby's own interpreter (`mrb_define_method_raw`'s own special case
for the name) and registered via `mrb_define_private_method`
regardless of visibility or POLY-ness.

Re-checked `LCF::EventCommand#initialize` (the other real class this
same earlier annotation round covered) specifically to avoid
duplicating a sibling round's own writeup: it has not yet joined
`mruby-lcf-compiled`'s own `owners:` list as of this round, so there is
no shipped-target finding to report for it here -- it does, however,
also appear in the real diagnostic's own "classes needing
`MRB_SET_INSTANCE_TT`" list alongside `LCF::MoveCommand`, a live lead
for whoever picks it up next.

**Zero real `bc2cpp.rb` bugs found**: this class's own method body
(five plain `SETIV`s, no arithmetic, no control flow beyond `ENTER`)
exercises nothing beyond opcode support this compiler has had since
its very first target. The only thing genuinely checked, not assumed,
was whether the pre-existing annotation was still honored correctly
end to end -- it was.

**Verified for real, the same way every real-source-touching round in
this file is**: `ruby -c` on every `.rb` file touched
(`tools/bc2cpp/compiled_gems.rb`, `mruby-lcf-compiled/mrbgem.rake`) --
both clean. This worktree could not run the real `build_config.rb` +
`rake` pipeline end to end -- a fresh-worktree gap this ADR already
anticipates, not a code problem: every `3rd/*` submodule (`3rd/mruby`
included) is uninitialized here (`git submodule status` shows every
entry `-`-prefixed), and no `rake` binary is even on `PATH`. Used the
same alternate, still-rigorous verification prior rounds fell back to
when they hit this exact class of gap: the real host `mrbc` binary
(found already built in this machine's separate, non-worktree checkout
at `/home/user/rpg-maker-clone/3rd/mruby/build/host/mrbc/bin/mrbc`) ran
the real `tools/bc2cpp/bc2cpp.rb` against this worktree's own real
`mruby-rpg2k`+`mruby-lcf`+`mruby-rgss` mrblib closed world, with the
exact `ONLY_OWNERS`/`OTHER_OWNERS`/`NATIVE_SRCS`/`SKIP_UNSUPPORTED`
environment `mruby-lcf-compiled/mrbgem.rake` itself computes (including
`LCF::MoveCommand` in `ONLY_OWNERS` via this round's own
`compiled_gems.rb` change) -- `EXIT: 0`, and the generated
`lcf_compiled_gen.cpp` diffs **byte-identical** against the same run
with `LCF::MoveCommand` left out of `ONLY_OWNERS` (expected: narrowing
emission never changes the whole-program registry or any other class's
own generated code). `g++ -fsyntax-only -std=c++17 -Wall -Wextra
-Winfinite-recursion` against the real, regenerated `register.cxx` plus
its own real generated file and the real mruby headers (from that same
separate checkout's `3rd/mruby/include` and its built
`build/host/include` for the generated `mruby/presym/id.h`) --
**zero errors, zero `-Winfinite-recursion` warnings**, only the same
pre-existing `-Wunused-but-set-variable`/`-Wunused-parameter` noise
already present in every already-shipped class in this file. Compiled
`register.cxx` to a real object file and confirmed with `nm -C`:
`LCF__MoveCommand_initialize_impl` is present and externally linked
(`T`), its `mrb_get_args` wrapper `LCF__MoveCommand_initialize`
correctly stays local (`t`), and the embedded-struct symbols
(`LCF__MoveCommand_ivars_type`/`_ivars_free`) are present too. Grepped
the freshly regenerated `lcf_compiled_gen.cpp` for the empty-name
`mrb_funcall(M, <reg>, "", ` shape directly: zero matches.

## Follow-up: LCF::EventCommand, and this compiler's eighth severe bug -- attr_reader/attr_writer/attr_accessor silently missing an ivar this same compiler embedded

A thirtieth round adds `LCF::EventCommand` (`mruby-lcf/mrblib/lcf.rb`) --
one decoded RPG2000 event-page/common-event/move-route command (code,
indent, an optional string argument, and an integer parameter list) --
to `mruby-lcf-compiled`, this gem's first new coverage target since the
original `LCF::File`-family work. Its own `#initialize` already carried
a real `# bc2cpp: (fixnum, fixnum, , )` annotation (the "26 more
annotations" follow-up, several rounds up) identifying `@code`/`@indent`
as Fixnum, but the class had never actually been added to this gem's
own `ONLY_OWNERS`. Both of its own two real bytecode-defined methods
compile clean, needing no new opcode work: `#initialize` (4 purely
mandatory arguments, no `super`, no block -- plain SETIVs) and `#param`
(`@parameters[i] || 0`, a Hash/Array GETIDX plus a `||` default).
`attr_reader :code, :indent, :string, :parameters` stays native,
uncompiled, as always.

**Confirmed for real, not trusted from the annotation alone, per this
round's own explicit brief**: cross-checked both registered methods
against the real diagnostic's own `== compiled entry points ==` listing
one by one --

```
LCF__EventCommand_initialize / LCF__EventCommand_initialize_impl  (LCF::EventCommand#initialize, arity 4)  [private -- use mrb_define_private_method, not mrb_define_method]
LCF__EventCommand_param / LCF__EventCommand_param_impl  (LCF::EventCommand#param, arity 1)
```

-- matching exactly what's registered below (`#initialize` private, per
mruby's own always-private-`#initialize` rule; `#param` public, no bare
`private`/`protected`/`public` anywhere in the real source). Grepped the
freshly generated `lcf_compiled_gen.cpp` for the empty-name
`mrb_funcall(M, <reg>, "", ` shape directly: zero matches.

**The real, verified answer on embedding is "no," not "yes" -- the
opposite of what the annotation alone would suggest, and the reason this
round exists at all.** `@code`/`@indent` are both provably Fixnum (the
annotation, and the real whole-program `EMBED` diagnostic, both agree),
and `#initialize` has pure mandatory arity with no `super`/block --
every condition `drop_unsafe_embeddings` already checked before this
round said "safe to embed." Checking one step further, exactly as this
round's own brief demanded ("confirm this for real against the actual
diagnostic output rather than just trusting the annotation"), turned up
a real, live, already-shipped correctness bug this compiler's embedding
pass had never guarded against: `LCF::EventCommand`'s own `attr_reader
:code, :indent, :string, :parameters` (`mruby-lcf/mrblib/lcf.rb`, right
above `#initialize`) covers the *exact same two ivars* `#initialize`
would otherwise embed.

**The bug:** a plain `attr_reader`/`attr_writer`/`attr_accessor`'s real C
implementation (`3rd/mruby/src/class.c`'s own `attr_reader`/
`attr_writer`) is a bare `mrb_iv_get`/`mrb_iv_set` against the ordinary
dynamic `iv_tbl` -- it has no way to know that this same class's own
SETIV codegen wrote the value into an embedded `RData` struct field
instead, since embedding an ivar means its own SETIV site stops calling
`mrb_iv_set` for it entirely (that's the entire point of embedding --
skip the dynamic `iv_tbl` lookup). So the native getter always reads
back `nil` (or the native setter's own write is simply invisible to
every compiled GETIV reader) regardless of what `#initialize` did, the
moment an embedded ivar's own bare name collides with one of these.
`drop_unsafe_embeddings` (`tools/bc2cpp/bc2cpp.rb`) had one gate --
whether `#initialize` itself compiles clean with pure mandatory arity --
and never checked whether some *other*, native accessor for the very
same ivar name already exists on that class. This is a structurally
different flavor of the same "invisible to a bytecode-only pass" family
this ADR has documented five times already (`attr_reader`/`writer`/
`accessor` and `Struct.new` invisible to the MONO/POLY *registry*, `SDEF`
and `class << self` invisible to it too) -- this time the blind spot is
in the *embedding* pass instead of the devirtualization one, even though
`build_registry`'s own `attr_reader`/`writer`/`accessor` case (added
several rounds up specifically to fix the registry side of this) had
already been recording exactly the fact needed to close it: a synthetic,
`irep: nil` `MethodDef` under the exact same owner and name.

**Confirmed live with a real toy repro, not just reasoned about**: a
minimal `Foo` class (a compiling `#initialize` that embeds `@x`, plus a
plain `attr_reader :x` installed the ordinary way), built and run
directly against this project's own real host mruby core
(`build/mruby/host/mrbc/lib/libmruby_core.a`, the exact `MRB_SET_INSTANCE_TT`/
`mrb_data_init`/`attr_reader` machinery every compiled gem's own
generated code and registration already uses) -- `Foo.new(42).x` returns
`nil`, not `42`, the moment `@x` is embedded.

**Confirmed live in already-shipped, already-registered code, not just
hypothetically -- four real classes, all in `mruby-rpg2k-compiled`,
found by re-running the real whole-program diagnostic before and after
the fix and diffing bc2cpp's own "classes needing `MRB_SET_INSTANCE_TT`"
list** (12 classes before this round's fix, 5 after -- the difference is
exactly these four plus `LCF::EventCommand` itself and two
not-yet-shipped classes, `Game::MessageConfig`/`LCF::MoveCommand`, whose
own embedding was already "real, verified, zero live effect today" the
same way every other checked-but-not-exploitable gap in this ADR is):

- `Game::State#x`/`#y`/`#direction` -- the hero's own saved position and
  facing, `attr_accessor :map, :x, :y, :direction`
  (`mruby-rpg2k/mrblib/game.rb`) -- silently returned `nil` (reads) and
  silently dropped every write the movement engine made through these
  three names on any compiled `Game::State` instance, the whole time
  `@x`/`@y`/`@direction` were three of its own 13 embedded fields.
- `Game::Map#id`/`#revision` -- `attr_reader :id, ..., :revision`. The
  latter is the exact counter `Scene::Map#tile_cache_valid?` watches to
  know the composed tile-layer render cache is stale (this class's own
  source comment: "anything that starts rewriting tiles must bump it or
  the change will not reach the screen") -- silently never advanced from
  a compiled reader's point of view.
- `Game::ChipSet#animation_type`/`#animation_speed` -- `attr_reader
  :name, :graphic, :animation_type, :animation_speed`.
- `Game::Switches#revision` -- `attr_reader :revision`, the exact
  counter this class's own source comment says "the map scene watches
  ... to know when a page might have flipped and its events need
  re-selecting."

All four compiled and linked clean, zero warnings, in the real,
currently-shipping `RPGMAKER_BC2CPP=1` build -- the same "compiles fine,
silently wrong at runtime" shape as this ADR's own three prior severe
bugs, just in a fourth distinct mechanism.

**The fix** (`tools/bc2cpp/bc2cpp.rb`'s `drop_unsafe_embeddings`): now
filters at the individual-ivar level, not just the whole-owner level --
an ivar is dropped from the embeddable set if a synthetic (`irep: nil`)
`MethodDef` exists under the *same owner* for either the bare ivar name
(a reader) or `"<name>="` (a writer), reusing the exact registry entries
`build_registry`'s own `attr_reader`/`writer`/`accessor` case (and, for
what it's worth, `Struct.new`'s and `NATIVE_SRCS`'s own merges) already
install. This can only ever remove an embedding that was never actually
safe -- it never turns a genuinely sound embedding unsound, the same
one-directional safety net every other `drop_unsafe_embeddings`-style fix
in this file already carries.

**Verified the fix actually changes the generated output**, not just
that it compiles: `Game__State_initialize_impl`'s own `@x = x` now reads
a plain `mrb_iv_set(M, self, mrb_intern_cstr(M, "@x"), r3);` where it
used to write straight into `DATA_PTR(self)`'s own struct field; no
`Game__State_ivars`/`Game__Map_ivars`/`Game__ChipSet_ivars`/
`Game__Switches_ivars`/`LCF__EventCommand_ivars` struct is generated at
all anymore, and none of the five classes appear in bc2cpp's own
"classes needing `MRB_SET_INSTANCE_TT`" diagnostic. `mruby-rpg2k-
compiled/src/register.cxx`'s own `MRB_SET_INSTANCE_TT(state, ...)`/
`(map, ...)`/`(chip_set, ...)`/`(switches, ...)` calls (each now
referencing a class the regenerated file never allocates as `RData` for)
are removed to match, with each registration block's own comment
corrected in place (and a full writeup added to this file's own top
comment) -- otherwise these four classes would keep being tagged
`MRB_TT_DATA` for no reason the generated code still needs, real drift
between the hand-written registration file and what the generator
actually produces. `tools/bc2cpp/compiled_gems.rb`'s own per-class
comments for `Game::State`/`Game::Map`/`Game::ChipSet`/`Game::Switches`/
`LCF::EventCommand` are corrected the same way. Every one of these five
classes' own real, registered entry points is completely unaffected
(identical arity/visibility/symbol) -- only the ivar access path
underneath a handful of them changed from an unsafe, silently-stale
struct-field/native-accessor split back to the ordinary, always-correct
dynamic `iv_tbl` both sides agree on.

**Other angles checked this round, no further live instance found**: the
same `natively_exposed?` check was run against every other already-
embedding class in the whole closed world (`Game::Screen`, `Game::
Transition`, `Game::Map::LRUBitmapCache`\-style `RPG2k::Scene::Map::
LRUBitmapCache`, `Game::Interpreter`, `RPG2k::Scene::VehicleWorld`) --
none of them expose an embedded ivar's own bare name via `attr_reader`/
`writer`/`accessor` at all (`Game::Screen`'s own dozens of embedded
Fixnum fields are each read through a real bytecode `def shake_offset;
@shake_offset; end`\-style getter instead, which *does* get this
compiler's own embedding-aware GETIV codegen, not a native accessor), so
none of them lost anything -- confirmed directly by the unchanged
`MRB_SET_INSTANCE_TT` list membership for all five, not merely assumed
from the source shape.

**Full-sweep re-check** (all forty-four now-shipped targets, rebuilt with
this round's own fix applied): every previously-shipped class's own
entry-point count matches exactly, the same forty-three counts this
ADR's own prior follow-ups already list, unchanged; new: `LCF::
EventCommand` (2).

**Verified for real, environment gap noted rather than worked around**:
a fresh worktree needed the same five mruby submodules (`3rd/mruby`,
`3rd/mruby-marshal`, `3rd/mruby-onig-regexp`, `3rd/mruby-stringio`,
`3rd/uni-algo`, `3rd/stb`) initialized and the same seven `patches/*.patch`
files applied by hand (a raw `rake -f 3rd/mruby/Rakefile` invocation runs
no CMake configure step, so none of this happens automatically the way
it does for the project's own real `cmake`\-driven build) that this
ADR's own `Game::Rng` follow-up already found and fixed in its own
environment; with those and `cp932_table`/`jis0208_table` pointed at this
environment's pre-staged tables, the real `RPGMAKER_BC2CPP=1` +
`rake -f 3rd/mruby/Rakefile` (host target) pipeline built a real host
`mrbc`, ran this round's own real whole-program `bc2cpp.rb` diagnostic
through it (every quoted listing above came from that real run), fully
regenerated both `lcf_compiled_gen.cpp` and `rpg2k_compiled_gen.cpp` via
their own real `mrbgem.rake` rules, and compiled `mruby-lcf-compiled/
src/register.cxx` all the way through its own presym-scan step with
**zero** compile errors -- then hit the same genuine, out-of-scope
environment gap this ADR's `Game::Rng`/`Game::Troop`/`Game::Vehicle`
follow-ups already documented and did not attempt to repair:
`mruby-rgss/src/lib.cxx` needs a real, built `lvgl.h`, which a raw `rake
-f 3rd/mruby/Rakefile` invocation has no step to build at all, before
`mruby-rpg2k-compiled/src/register.cxx` (ordered after `mruby-rgss` in
this build's own dependency graph) is ever reached.

Verified both touched register.cxx files the same alternate, still-
rigorous way this ADR's `Game::Rng`/`Game::Troop` follow-ups already
established for exactly this gap: `g++ -fsyntax-only -std=gnu++17 -Wall
-Wextra -Winfinite-recursion` against each real regenerated file plus
its own real `register.cxx` and the real mruby headers (including the
real generated `mruby/presym/id.h`, borrowed from this same run's own
host `mrbc` bootstrap build, which needs no RGSS/LVGL header at all) --
both: **zero errors, zero `-Winfinite-recursion` warnings** (the only
warnings anywhere are the same pre-existing, unrelated
`-Wunused-but-set-variable` ones this ADR's own `Game::Rng` follow-up
already found, not introduced by this round). Re-confirmed the empty-
name `mrb_funcall` grep against both full-owner generated files directly:
zero matches. This does not confirm the final *link* (blocked on LVGL, as
above) but does confirm every declaration this round's new code and its
fix reference is type-correct and consistent with the real, already-
shipped classes around it -- left for a correctly-configured checkout
(with `3rd/lvgl` actually built) to confirm the final link and runtime
diff.

## Follow-up: LCF::Sections

An independent round adds `LCF::Sections` (`mruby-lcf/mrblib/lcf.rb`) to
`mruby-lcf-compiled` -- the sequential-section container
`LCF::File#initialize` builds exactly once, whenever its own `schema` is
an Array (currently only `LCF::MapTree`'s own map-properties-table +
tree-order + party/vehicle-positions schema). Grepped the whole tree
first for any other construction site or subclass, this project's own
established construction-site-safety check: none exist.

All 4 of its own real bytecode-defined methods compile clean, confirmed
directly against the real diagnostic's own `== compiled entry points ==`
listing rather than assumed from the class's small size: `#initialize`
(2 plain Hash/Array literal SETIVs, no arguments at all), `#add` (a
Hash `[]=`/Array `#push` pair), `#key?` (a POLY `@by_name.key?` forward),
and `#[]`. `#[]`'s own `idx.is_a? Symbol` type check -- called out ahead
of time as the one shape in this class that looked like it might need
new opcode work -- needed none: it compiles to the same generic
`mrb_funcall(M, r3, "is_a?", 1, r4)` fallback (a POLY send into the
native, non-bytecode `Kernel#is_a?`) every other already-shipped
`x.is_a? Foo`/`x.nil?` guard in this codebase already takes, and the
`if (!mrb_test(r3)) goto L28;` that follows it is the same already-
supported JMPNOT branch shape every other compiled guard clause here
already uses -- not a conditional/branch opcode needing any special
case. `#method_missing`/`#respond_to_missing?` are out of scope, same as
every other method_missing-using class in this codebase -- confirmed in
the real diagnostic's own `== skipped (unsupported, left on the
interpreter) ==` list, not assumed from the name alone.

`@by_name`/`@list` are a Hash and an Array respectively -- never
Fixnum/Symbol -- so `IvarLayout` correctly infers nothing embeddable
here, and this class has no `attr_reader`/`writer`/`accessor` at all, so
there is nothing for `drop_unsafe_embeddings` to have to reject either
way: confirmed directly, `LCF::Sections` never appears in bc2cpp's own
"classes needing `MRB_SET_INSTANCE_TT`" diagnostic.

**Verified for real:** with `mruby-lcf-compiled`'s own `ONLY_OWNERS`
regenerated against the whole `mruby-rpg2k`+`mruby-lcf`+`mruby-rgss`
closed world (the same set `mrbgem.rake` feeds in), the real diagnostic
shows all four methods registered
(`LCF__Sections_initialize`/`_add`/`_key_`/`___`), zero `#error` markers
in the generated output, and zero matches for the broken empty-name
`mrb_funcall(M, <reg>, "", ` shape. `g++ -fsyntax-only -std=gnu++17
-Wall -Wextra -Winfinite-recursion` against the updated `register.cxx`
(real `3rd/mruby/include` headers plus an already-generated real
`mruby/presym/id.h`) reports **zero** errors and **zero**
`-Winfinite-recursion` warnings -- the same environment-gap fallback
prior rounds used when the full SDL2-linked engine build wasn't
available, since a full `RPGMAKER_BC2CPP=1` engine rebuild needs
submodules and native libraries beyond this container's own preinstalled
set.


## Follow-up: LCF::Tree, and a direct re-verification of the eighth severe bug's own fix against a second, checked-but-not-live collision

A thirty-first round adds `LCF::Tree` (`mruby-lcf/mrblib/lcf.rb`, right
above `LCF::EventCommand`) to `mruby-lcf-compiled` -- one decoded map-tree
section: the currently-selected map id plus the flat list of every map id
in tree order (`LCF::MapTree`'s own `:tree` section, read by both
`LCF#read_section`'s `:Tree` case and `LCF#to_rb`'s own `:Tree` schema-type
branch). `#initialize` is the ONLY real bytecode-defined method on this
class (`attr_reader :selected_id, :maps` stays native, uncompiled, as
always) and it compiles clean: 2 purely mandatory arguments, no `super`,
no block, needing no new opcode work. Confirmed directly against the real
diagnostic's own `== compiled entry points ==` listing, not trusted from
arity alone:

```
LCF__Tree_initialize / LCF__Tree_initialize_impl  (LCF::Tree#initialize, arity 2)  [private -- use mrb_define_private_method, not mrb_define_method]
```

**This round's own explicit brief was to re-check the immediately
preceding round's fix (the eighth severe bug, `drop_unsafe_embeddings`
never checking a same-owner `attr_reader`/`writer`/`accessor` collision)
against this exact class**, since `LCF::Tree`'s own `attr_reader
:selected_id, :maps` covers precisely the two names `#initialize` writes,
the identical shape `LCF::EventCommand`'s `attr_reader :code, :indent`
already exposed one round up. Checked directly rather than assumed clean
by analogy: the real diagnostic's own `== classes needing
MRB_SET_INSTANCE_TT(..., MRB_TT_DATA) ==` listing does **not** include
`LCF::Tree`, and the regenerated `LCF__Tree_initialize_impl` writes both
`@selected_id` and `@maps` via plain `mrb_iv_set` -- no `mrb_data_init`,
no `LCF__Tree_ivars` struct.

That confirms embedding is correctly suppressed, but on its own doesn't
distinguish *why*: unlike `LCF::EventCommand`, this class carries no
`# bc2cpp:` type annotation at all, and neither `@selected_id` nor `@maps`
traces to a literal or an annotated argument -- both appear only in the
diagnostic's own `report_annotation_candidates` list (`CANDIDATE
LCF::Tree#initialize, arg 1/2 -> @selected_id` / `arg 2/2 -> @maps`), never
as a raw embedding proposal. So by itself this round is a *second*,
independent reason embedding never happens here (no type information ever
reaches the embedding pass), not actually a live re-confirmation of the
`attr_reader`-collision fix specifically -- the interesting question this
round's brief asked (does the *collision* guard, not just the missing
annotation, hold here too?) needed a real repro to test, not lucky
absence.

**Verified with a temporary, experimental annotation, reverted before this
change**: added `# bc2cpp: (fixnum, )` immediately above
`LCF::Tree#initialize` (matching `@selected_id`'s own real construction
sites -- `LCF.read_section`'s `:Tree` case and `LCF#to_rb`'s own `:Tree`
branch both always pass a `read_ber` result, genuinely Fixnum), re-ran the
exact same real diagnostic, and confirmed `LCF::Tree` still does **not**
appear in the `MRB_SET_INSTANCE_TT` list, and the regenerated
`LCF__Tree_initialize_impl` still writes `@selected_id` via plain
`mrb_iv_set`, never `mrb_data_init`, with the annotation in place. This is
the direct, real confirmation: `attr_reader :selected_id` would have
collided with an embedded `@selected_id` exactly the same way
`LCF::EventCommand`'s `attr_reader :code, :indent` did, and
`natively_exposed?` (the prior round's own fix) correctly suppresses it
here too -- not merely inferred safe because nothing was ever proposed.
The experimental annotation was reverted immediately afterward; the real,
shipped `mruby-lcf/mrblib/lcf.rb` carries no annotation on this class, so
in the actual shipped build the missing-annotation gap and the
attr_reader-collision guard are both independently sufficient to keep this
safe today. `@maps` (an Array, from a schema-decoded id list) was never a
Fixnum/Symbol embedding candidate under either mechanism.

Re-confirmed the empty-name `mrb_funcall(M, <reg>, "", ` grep against the
freshly regenerated `lcf_compiled_gen.cpp` directly: zero matches, same as
every prior round.

**Full-sweep re-check**: the whole-program registry dump shows `:maps` and
`:selected_id` each `MONO (1 def: LCF::Tree)` -- the synthetic,
`attr_reader`-installed `MethodDef` `build_registry`'s own case already
records, with no other real bytecode `def` anywhere colliding on either
name -- and every previously-shipped class's own entry-point count is
unchanged; new: `LCF::Tree` (1).

**Verified via the same alternate, still-rigorous path this ADR's prior
rounds already established for the real environment's own LVGL gap**: a
real `RPGMAKER_BC2CPP=1` + `rake -f 3rd/mruby/Rakefile` (host target) run
regenerated `lcf_compiled_gen.cpp` through its own real `mrbgem.rake` rule
and got as far as preprocessing (presym-scanning) `mruby-lcf-compiled/src/
register.cxx` cleanly before hitting the same, already-documented
`mruby-rgss/src/lib.cxx` -> `lvgl.h` wall (`3rd/lvgl` not built in this
environment). `g++ -fsyntax-only -std=gnu++17 -Wall -Wextra
-Winfinite-recursion` against the real regenerated file plus its own real
`register.cxx` and the real mruby headers (including the real generated
`mruby/presym/id.h`, from this same run's own host `mrbc` bootstrap, which
needs no RGSS/LVGL header at all): **zero errors, zero
`-Winfinite-recursion` warnings**, exit code 0 -- the only warnings
anywhere are the same pre-existing, unrelated `-Wunused-but-set-variable`/
`-Wunused-parameter` ones every prior round already found. Left for a
correctly-configured checkout (with `3rd/lvgl` actually built) to confirm
the final link and a runtime diff.

## Follow-up: adversarial full-sweep bug hunt -- one confirmed hand-written/generator drift, no ninth live embedding bug, two checked-but-not-live structural gaps

Not a coverage round: a dedicated adversarial sweep across `bc2cpp.rb`
itself, re-verifying the eighth bug's own fix and specifically hunting
for any sibling instance the fix round might have missed, any other
class among the 45 already-shipped owners with the same
compiling-`#initialize`-plus-native-accessor shape, and any further
structural gap in `build_registry`/`ArgTypes`/`IvarLayout` the eight
already-fixed bugs did not cover.

**`natively_exposed?` itself re-verified sound**: it checks
`(@registry[name] || []).any? { |d| d.owner == owner && d.irep.nil? }`,
called once for the bare ivar name (a reader collision) and once for
`"#{name}="` (a writer collision) -- both directions covered. It is
also *not* attr_reader-specific: `build_registry`'s own `Struct.new(...)
do ... end` case (this compiler's fourth severe bug, several rounds up)
installs the exact same shape of synthetic, `irep: nil` `MethodDef`
for each member name and `"#{member}="`, under the Struct's own real
owner -- so a Struct-generated accessor for an embedded ivar's own name
would be caught by this same check with zero further work, not a
separate gap. Confirmed structurally by reading `natively_exposed?`'s
own one-line body against both call sites (`build_registry`'s
attr_reader/writer/accessor case and its Struct.new case), not just
assumed from the two features sharing a comment.

**Whole-program diagnostic re-run against both real full owner sets**
(`mruby-rpg2k-compiled`'s 41 owners and `mruby-lcf-compiled`'s 7, the
exact `MRBC=... OUT_SYMBOL=... ONLY_OWNERS=... OTHER_OWNERS=...
NATIVE_SRCS=... SKIP_UNSUPPORTED=1 ruby tools/bc2cpp/bc2cpp.rb
<mrblib files>` invocation each gem's own `mrbgem.rake` runs at build
time, replayed directly against this environment's pre-built host
`mrbc`) -- diffing bc2cpp's own "classes needing `MRB_SET_INSTANCE_TT`"
listing (identical both times, since it runs over the whole closed
world, not just `ONLY_OWNERS`: `Game::Transition`, `Game::Screen`,
`Game::Interpreter`, `RPG2k::Scene::VehicleWorld`,
`RPG2k::Scene::Map::LRUBitmapCache` -- the last two are real embedding
candidates that simply aren't compiled owners, confirmed by their
absence from either gem's own `target_owners`) against every real
`MRB_SET_INSTANCE_TT` call actually still in each gem's own
`register.cxx` turned up exactly one mismatch:

**Confirmed real: `mruby-lcf-compiled/src/register.cxx`'s own
`MRB_SET_INSTANCE_TT(move_command, MRB_TT_DATA);` was stale.**
`LCF::MoveCommand` (`mruby-lcf/mrblib/lcf.rb`) carries a bare
`attr_reader :command_id, :parameter_string, :parameter_a,
:parameter_b, :parameter_c` -- the *exact* same native-accessor/
embedded-ivar collision shape as `LCF::EventCommand`'s own (the
triggering case for the eighth severe bug, a few commits up in this
same file) and the four already-shipped `Game::` classes that fix was
written for. `natively_exposed?`/`drop_unsafe_embeddings` correctly
drops all four of `LCF::MoveCommand`'s own provably-Fixnum ivars
(`@command_id`/`@parameter_a`/`@parameter_b`/`@parameter_c`) from
embedding as a result -- confirmed directly against the real
regenerated `lcf_compiled_gen.cpp`: zero `_ivars` structs, zero
`mrb_data_init` calls anywhere in the file, and
`LCF__MoveCommand_initialize_impl`'s own body writes all five ivars
(the four above plus `@parameter_string`) via plain `mrb_iv_set`,
exactly like `LCF::EventCommand`'s. `LCF::MoveCommand` does **not**
appear in the re-run diagnostic's "classes needing
`MRB_SET_INSTANCE_TT`" listing at all. But the eighth bug's own fix
round -- which touched this exact file to add `LCF::EventCommand`'s own
registration and correct the *other* four classes' `register.cxx`
entries -- never revisited `LCF::MoveCommand`'s own block sitting a few
lines below in the same function, even though it was already a shipped
embedding target hit by the exact same fix. `register.cxx`'s own
comment (and `tools/bc2cpp/compiled_gems.rb`'s matching one) kept
asserting the pre-fix behavior ("the generated #initialize body really
does call `mrb_data_init`... `LCF::MoveCommand` appears in bc2cpp's own
`MRB_SET_INSTANCE_TT` diagnostic") -- both now simply false against the
current generator.

**Checked whether this drift is merely stale documentation or a second
live embedding bug, the same rigor the eighth bug's own writeup used**:
tagging a class `MRB_SET_INSTANCE_TT(..., MRB_TT_DATA)` with no compiled
code ever calling `mrb_data_init` for it leaves every real instance's
`RData` payload (`data`/`type`) permanently `NULL` (`3rd/mruby/src/gc.c`'s
own `mrb_obj_alloc` zero-fills the whole `RVALUE` before tagging it).
Read every `MRB_TT_CDATA`-handling site in `3rd/mruby/src/{gc,variable,
class,object,etc}.c` directly: ivar mark/free/copy (`mrb_gc_mark_iv`/
`mrb_gc_free_iv`/`mrb_iv_copy`, used by GC and by `#dup`/`#clone`) all
treat `MRB_TT_CDATA` identically to `MRB_TT_OBJECT`, and the GC's own
data-free path (`gc.c`) checks `if (d->type && d->type->dfree)` before
ever touching the (`NULL`) type pointer -- so a `NULL`-payload
`MRB_TT_CDATA` object is inert, not unsafe, at the mruby-core level. A
grep of every `mrb_data_get_ptr`/`mrb_data_check_type`/`DATA_PTR`/
`DATA_TYPE` use in this project's own `mruby-lcf*`/`mruby-rpg2k-compiled`
sources for `move_command`/`MoveCommand` found none, confirming nothing
anywhere actually dereferences the never-allocated payload. **Verdict:
real, confirmed drift between the hand-written registration and what
the current generator produces -- exactly the kind of divergence this
project's own established discipline always corrects (see this file's
own `Game::State`/`Map`/`ChipSet`/`Switches` writeup for the precedent)
-- but not, on direct inspection, a second live silently-wrong-behavior
bug the way the eighth one was: no compiled code path or mruby-core
mechanism currently observes the difference.**

**Fixed to match**: removed the stale `MRB_SET_INSTANCE_TT(move_command,
...)` call from `mruby-lcf-compiled/src/register.cxx` and rewrote both
its own comment and `tools/bc2cpp/compiled_gems.rb`'s matching one to
describe the real, current behavior (no embedding, plain `mrb_iv_set`,
same shape as `LCF::EventCommand`). Verified the edit itself compiles
clean against the real regenerated `lcf_compiled_gen.cpp` and real mruby
headers the same alternate way the `Game::Rng`/`Game::Troop`/this file's
own eighth-bug follow-up already established for this environment's
LVGL gap: `g++ -fsyntax-only -std=gnu++17 -Wall -Wextra
-Winfinite-recursion` against the edited `register.cxx` plus the fresh
`lcf_compiled_gen.cpp` -- zero errors, zero `-Winfinite-recursion`
warnings, only the same pre-existing `-Wunused-but-set-variable` noise
this ADR already documents as unrelated.

**Two further structural gaps found, checked carefully, and confirmed
NOT currently live -- documented rather than "fixed" against nothing**:

- `natively_exposed?`'s own `d.owner == owner` check cannot see a
  collision registered under `extract_native_method_names`' own flat
  pseudo-owner (`'<native>'`, used for every name pulled from
  `NATIVE_SRCS` -- RGSS's C++ and mruby-core's C) instead of a real class
  name, by that mechanism's own deliberate design (its own comment: "not
  an owner class... neither is needed to make MONO/POLY accounting
  sound again"). So a class with a compiling `#initialize` that embeds
  ivar `@x` while that *same* class also has a `NATIVE_SRCS`-registered
  C/C++ method literally named `x` (not an `attr_reader`, not a
  `Struct.new` member -- an actual hand-written `mrb_define_method`)
  would slip through unprotected, the same shape as the eighth bug via a
  third installation mechanism. Checked for a live instance the same way
  the eighth bug's own writeup checked its four: this only matters for a
  class with BOTH a real bytecode `#initialize` (this compiler's whole
  embedding gate) AND a native accessor of the colliding name on the
  identical class. The only native-implemented owner among the 45,
  `RGSS::Sprite`, has no bytecode `#initialize` at all (its own
  `mrblib/lib.rb` never defines one; construction is entirely native, in
  `mruby-rgss/src/lib.cxx`) -- confirmed directly against the real
  source, not assumed -- so `drop_unsafe_embeddings`' own prior gate
  (`@registry['initialize']&.find { |d| d.owner == owner }`, which only
  ever matches a *bytecode* definition) already excludes it regardless,
  and no other owner is reopened by any `NATIVE_SRCS` file. Not live
  today; would need bc2cpp.rb's own `natively_exposed?` to compare
  against native defs by name alone (dropping the `d.owner == owner`
  check for `'<native>'`-owned entries specifically) if a future round
  ever adds a native-reopened, bytecode-`#initialize`-having owner.

- `Enumerable`'s own real methods (`#select`/`#reduce`/`#sort_by`/
  `#min_by`/`#max_by`/`#group_by`/`#partition`/`#none?`/`#one?`/
  `#each_slice`/`#each_cons`/`#tally`/`#each_with_object`/... -- confirmed
  this project's own real, shipped build does load them:
  `build_config.rb`'s own `rpg_maker_gems` declares `conf.gem core:
  'mruby-enum-ext'` unconditionally, including for the `wio`
  single-format build) are themselves real *bytecode*, not C, defined in
  `3rd/mruby/mrbgems/mruby-enum-ext/mrblib/enum.rb` -- a file neither
  `closed_world_srcs` (only this project's own `mruby-rpg2k`/`mruby-lcf`/
  `mruby-rgss` `mrblib`) nor `NATIVE_SRCS` (C/C++ sources only; irrelevant
  to a `.rb` file) ever feeds into `bc2cpp.rb` at all, in either gem's
  own `mrbgem.rake`. `Array` does not reimplement any of these itself --
  grepped `3rd/mruby/src/array.c`'s own method table directly: no
  `select`/`reduce`/`map`/`sort_by`/`none?`/etc. entry anywhere, so
  `Array`/`Hash` genuinely dispatch these to `Enumerable`'s own
  bytecode body, invisible to this registry -- a real, structural analog
  of the already-fixed `Game::Shop#name`/`Game::MoveRoute#empty?`/
  operator-regex bugs (this compiler's first, second and fourth severe
  bugs), just via a third, distinct invisibility mechanism (a *bundled
  optional mrbgem's own bytecode stdlib*, not core C, not this project's
  own source). Confirmed a live-looking near-miss and then confirmed it
  is not actually exploitable: `Game::Weather#none?` (`@type == 0`) is
  the whole program's only visible `:none?` definition, so the registry
  calls it MONO -- if any *compiled* method called `.none?` on a
  non-`Game::Weather` enumerable without a block, it would devirtualize
  straight into `Game__Weather_none__impl` on the wrong receiver.
  Grepped every real `.none?`/`.select`/`.reduce`/`.sort_by`/`.min_by`/
  `.max_by`/`.group_by`/`.partition`/`.each_slice`/`.each_cons`/`.tally`/
  `.one?`/`.take_while`/`.drop_while`/`.each_with_object`/`.minmax`/
  `.flat_map` call site across the whole closed world directly: the only
  two real `.none?` sites are `RPG2k::Scene::Map#draw_weather`'s `w =
  @state.weather; w.none?` (`RPG2k::Scene::Map` -- not `::Base` -- is not
  a compiled owner at all, and `Game::State#weather` is a plain
  `attr_reader` for a `Weather.new` set exactly once in `#initialize`, so
  `w` is provably always the one real `Game::Weather` even if this
  *were* compiled) and `Game::Battle#<method>`'s `@allies.none? { |a|
  ... }`, which carries a real block (`SENDB`) -- an opcode
  `compile_insn` has no case for at all (confirmed: only `SEND0`/`SEND`
  dispatch to `compile_send`), so the containing method never compiles
  in the first place, the same established "a genuine Ruby block takes
  a method out of scope entirely" pattern this ADR already documents
  dozens of times over. Directly confirmed against the real regenerated
  output too: grepped both `rpg2k_compiled_gen.cpp` and
  `lcf_compiled_gen.cpp` for a `MONO :<name>` devirtualization comment
  naming any Enumerable-only method (`select`/`reduce`/`sort_by`/
  `min_by`/`max_by`/`group_by`/`partition`/`none?`/`one?`/`tally`/
  `each_slice`/`each_cons`/`take_while`/`drop_while`/`each_with_object`/
  `minmax`/`flat_map`/`map`) -- zero matches in either file. Not live
  today; worth re-checking whenever a future round adds a compiled
  owner whose own body calls one of these names (without a block) on a
  receiver that is not provably the one class currently defining that
  name.

**Also checked, no issue found**: a fresh scan for a *third* real,
already-shipped owner reopened across three or more `mrblib` files (the
task's own `Game::State`-shaped concern, its two real reopenings already
merged correctly by `build_registry`'s ordinary per-file `walk` calls
sharing one `registry` hash) -- the only bare-name collisions found
(`Battle` across `game/battle.rb`/`scene/battle.rb`/
`scene/battle_rpg2k3.rb`, `Map` across `game/battle_support.rb`/
`game.rb`/`scene/map.rb`) are each genuinely *different* classes in
different namespaces (`Game::Battle` vs `RPG2k::Scene::Battle` vs
`RPG2k3::Scene::Battle`; `Game::Map` vs `RPG2k::Scene::Map`), confirmed
by reading each `class` line's own full nesting and superclass directly
-- no class among the 45 owners is actually reopened in three or more
files. `Game::Party`'s and `LCF::Array2D`'s own `include Enumerable`
were also checked directly (the task's own Comparable/Enumerable
mixin-registration concern): the bare `include Enumerable` call itself
registers nothing under either class in `build_registry` (no `CLASS`/
`MODULE` opcode fires for a plain `include` send), so no false-MONO risk
comes from the `include` itself -- the real risk is the one already
covered two paragraphs up, on `Enumerable`'s own methods being invisible
outright, not on them being wrongly counted MONO once visible.

**Verified for real**: the real, opt-in `RPGMAKER_BC2CPP=1` whole-program
diagnostic was re-run against this environment's pre-built host `mrbc`
for both `mruby-rpg2k-compiled`'s full 41-owner set and
`mruby-lcf-compiled`'s full 7-owner set (the exact env-var invocation
each gem's own `mrbgem.rake` uses), not read from source alone. The one
fix in this follow-up (`mruby-lcf-compiled/src/register.cxx`,
`tools/bc2cpp/compiled_gems.rb`) touches comments and one
`MRB_SET_INSTANCE_TT` call only -- no `bc2cpp.rb` change, since
`natively_exposed?`'s own general mechanism already produces the correct
(non-embedding) output for `LCF::MoveCommand` today; the drift was
entirely in the hand-written registration file lagging behind it.
`g++ -fsyntax-only` against the edited `register.cxx` and a freshly
regenerated `lcf_compiled_gen.cpp`: zero errors, zero
`-Winfinite-recursion` warnings.

## Follow-up: Game::MessageConfig -- a direct, real stress-test of the eighth severe bug's fix, one genuinely new opcode gap found (RETSELF), no live bug

Adds `Game::MessageConfig` (`mruby-rpg2k/mrblib/game.rb`) to
`mruby-rpg2k-compiled`'s owners -- the Message Options settings object a
`Game::State#message_config` holds one of (window transparency, text
position, whether the window stays put vs. dodges the hero, whether other
events keep running while the message shows, and the face-graphic
selection). Picked deliberately, not incidentally: every one of this
class's own 8 ivars (`@transparent`, `@position`, `@position_fixed`,
`@continue_events`, `@face_name`, `@face_index`, `@face_right`,
`@face_flipped`) is covered by a plain `attr_accessor` (two calls, 4 names
each) -- the exact shape the eighth severe bug (`attr_reader`/
`attr_writer`/`attr_accessor` silently missing an ivar this same compiler
embedded into a real `RData` struct) was about, and the exact shape a
later round's own full-sweep caught a stale instance of on
`LCF::MoveCommand`. `#initialize` (arity 0, all eight ivars set
unconditionally, the last four via a self-call into `#clear_face`)
compiles clean, so this is a real embedding *attempt* here, not moot by
non-mandatory arity the way most of this file's other
`attr_accessor`-heavy classes are.

**Checked each of the 8 ivars' own provable type directly, not assumed
from the `attr_accessor` line alone**: `@transparent`/`@position_fixed`/
`@continue_events`/`@face_right`/`@face_flipped` are always `true`/`false`
(a `cond ? true : false` ternary in `#initialize`/`#clear_face`/
`#load_h`) and `@face_name` is always a String (`''` literal) -- none of
these five is ever a `:fixnum`/`:symbol` embedding candidate in the first
place, since `IvarLayout` only ever classifies those two types regardless
of `attr_accessor`. That leaves two real Fixnum-shaped candidates, and
they resolve two different ways:

- **`@face_index`**: provably Fixnum (`clear_face` sets it via a plain
  `LOADI_0`-fed `SETIV`, reached from `#initialize` only through a
  self-call). Confirmed live in the real diagnostic's own `== ivar
  embedding ==` section: `EMBED Game::MessageConfig#@face_index (fixnum)`
  -- `IvarLayout` genuinely proposes it. But `attr_accessor :face_index`
  installs the same synthetic, `irep: nil` native reader/writer
  `natively_exposed?` was built to catch, and it does: confirmed directly
  against the real regenerated `rpg2k_compiled_gen.cpp`, `Game::
  MessageConfig` does **not** appear in bc2cpp's own "classes needing
  `MRB_SET_INSTANCE_TT(..., MRB_TT_DATA)`" diagnostic, and the regenerated
  `Game__MessageConfig_initialize_impl`/`Game__MessageConfig_clear_face_
  impl` write `@face_index` via plain `mrb_iv_set`, never `mrb_data_init`/
  a `_ivars` struct. This is the live, real positive test the eighth bug's
  fix was written for -- not a hypothetical one.
- **`@position`**: assigned `@position = POS_BOTTOM` in `#initialize`, a
  `GETCONST`-fed value (confirmed in the regenerated code: a
  `mrb_const_get`/`bc2cpp_const_try` chain feeds the `SETIV`), not a
  literal. `IvarLayout`'s own fixnum-classification only ever fires on
  `LOADI`/fixnum-fastpath-arithmetic-fed `SETIV`s, never on a constant
  lookup -- so `@position` is **not even proposed** as an embedding
  candidate at all: confirmed, no `EMBED Game::MessageConfig#@position`
  line anywhere in the real diagnostic. This is a distinct, independent
  reason from `@face_index`'s own (never reaches the embedding pass, vs.
  reaching it and then being correctly vetoed) -- the same
  two-reasons-at-once shape this file's own `LCF::Tree` follow-up already
  documented for a sibling gem, confirmed here rather than assumed
  identical by analogy.

**4 of its own 5 real bytecode-defined methods compile clean**:
`#initialize`, `#face?` (`!@face_name.nil? && !@face_name.empty?`),
`#clear_face` (four plain `SETIV`s), and `#to_h` (a literal Hash of all 8
ivars). **`#load_h` is the one gap, and a genuinely new one for this
compiler**: both its early-exit `return self unless h` and its own
trailing bare `self` disassemble to `RETSELF` -- mrbc's own dedicated
opcode for returning `self` specifically (distinct from `RETURN`/
`RETNIL`/`RETFALSE`/`RETTRUE`), confirmed by disassembling this exact
method with the real host `mrbc -v`. `compile_insn` has no `when
'RETSELF'` case at all (confirmed: grepped `bc2cpp.rb` for it, zero hits)
-- a real, previously-undocumented opcode gap, not a bug: `SKIP_
UNSUPPORTED=1` just leaves the whole method on the interpreter, this
compiler's own always-safe fallback. Checked it does not regress the
other four classes sharing the `:load_h` name (`Game::Screen`,
`Game::Weather`, `Game::Vehicle`, `Game::Timer`): all four use a bare
`return unless h` with no explicit value, which disassembles to `RETNIL`
instead, so all four still compile -- confirmed live in the real
diagnostic's own `== compiled entry points ==` listing, which shows
exactly those four `_load_h_impl` symbols, not this class's. Not fixed
here (no new `bc2cpp.rb` opcode work) since nothing in this round needs
`#load_h` compiled -- left as a real, confirmed-safe structural gap
(worth adding a `RETSELF` case, the same one-line shape as `RETNIL`'s,
whenever a future round's own target needs it).

`#initialize` is private (Ruby's own implicit privacy), registered with
`mrb_define_private_method` like every other embedding-attempted
`#initialize` in this file; confirmed live in the real diagnostic's own
`== compiled entry points ==` listing (`[private -- use
mrb_define_private_method, not mrb_define_method]`). The other 3
registered methods are plain `mrb_define_method`.

**Bonus full-sweep re-check** (this project's own established discipline
of never trusting an isolated round's fix without re-checking siblings,
most recently exercised by the `LCF::MoveCommand` stale-tag finding
above): diffed the real diagnostic's "classes needing
`MRB_SET_INSTANCE_TT`" listing (`Game::Transition`, `Game::Screen`,
`Game::Interpreter`, `RPG2k::Scene::VehicleWorld`, `RPG2k::Scene::Map::
LRUBitmapCache`) against every real `MRB_SET_INSTANCE_TT` call actually
in `mruby-rpg2k-compiled/src/register.cxx` and `mruby-lcf-compiled/src/
register.cxx`: exactly three real calls (`screen`, `transition`,
`vehicle_world`), matching the three diagnostic entries that are actual
compiled owners (`Game::Interpreter`/`RPG2k::Scene::Map::
LRUBitmapCache` are real embedding candidates but were never added as
owners in either gem, confirmed by their absence from both gems' own
`target_owners`). No drift found -- no sibling of the `LCF::MoveCommand`
staleness bug anywhere in either `register.cxx` today. Also
cross-checked every other owner whose own raw `EMBED` proposal gets
vetoed in the final listing despite a compiling `#initialize`
(`Game::ChipSet`, `Game::Switches`, `Game::Variables`, `Game::Map`,
`Game::State`) against `register.cxx`'s own comments for each: all five
already carry an explicit, correct "`drop_unsafe_embeddings` correctly
refuses" writeup from an earlier round -- no new undocumented veto found
among them either.

Verified for real: the exact `RPGMAKER_BC2CPP=1`/`SKIP_UNSUPPORTED=1`
whole-program diagnostic invocation each gem's own `mrbgem.rake` uses was
replayed directly against this environment's pre-built host `mrbc`
(`3rd/lvgl`/SDL2 submodules are not checked out in this environment,
the same already-documented gap prior rounds hit -- confirmed again this
round rather than assumed unchanged). `g++ -fsyntax-only -std=gnu++17
-Wall -Wextra -Winfinite-recursion` against the edited `register.cxx`
plus the freshly regenerated `rpg2k_compiled_gen.cpp`: zero errors, zero
`-Winfinite-recursion` warnings, only the same pre-existing
`-Wunused-but-set-variable`/`-Wunused-parameter` noise every prior round
already documents. The empty-method-name `mrb_funcall(M, <reg>, "", `
grep against the freshly regenerated file: zero matches, same as every
prior round.

## Follow-up: LCF::Array1D, a mixed compiling/non-compiling target

A new round adds `LCF::Array1D` (`mruby-lcf/mrblib/lcf.rb`, right above
`LCF::Array2D`) to `mruby-lcf-compiled` -- the sequential chunk-id ->
raw-bytes record every `LCF::File`-family object (`Database`, `MapTree`/
`MapUnit`'s own sub-records, `SaveData`'s own actors/party/etc.) actually
decodes through at the bottom of the schema chain. Substantially more
complex than `LCF::Tree`/`LCF::Sections` (the two most recent additions
to this gem): 11 real bytecode-defined methods, not 1-4, so this round's
own brief was explicit that under-compiling is fine and expected --
document exactly what compiles and why per method, rather than force
every method through.

**5 of its own 11 real bytecode-defined methods compile clean**,
confirmed directly against the real `== compiled entry points ==`
listing, not assumed from arity alone:

```
LCF__Array1D___ / LCF__Array1D____impl  (LCF::Array1D#[], arity 1)
LCF__Array1D_key_ / LCF__Array1D_key__impl  (LCF::Array1D#key?, arity 1)
LCF__Array1D_int16_values / LCF__Array1D_int16_values_impl  (LCF::Array1D#int16_values, arity 1)
LCF__Array1D_delete / LCF__Array1D_delete_impl  (LCF::Array1D#delete, arity 1)
LCF__Array1D____ / LCF__Array1D_____impl  (LCF::Array1D#[]=, arity 2)
```

All five are public (no `[private -- ...]` tag, unlike every compiled
`#initialize` in this gem), pure mandatory arity, no `super`, no block --
`#[]` resolves a `Symbol` key via `#sym2idx` (an ordinary POLY
`mrb_funcall`) then does a Hash/Array-shaped GETIDX plus the `@decoded`
cache lookup/`||` chain; `#key?`/`#delete` are plain `@data` GETIDX/
nil-check/SETIDX; `#int16_values` is a single `#unpack('s<*')` POLY send
guarded by a `&&`; `#[]=` is an elem lookup plus an `elsif` chain against
`@schema` -- every shape already established by prior rounds, needing
zero new `bc2cpp.rb` opcode work.

**6 more real methods stay interpreted**, each confirmed against its own
real generated `#error` marker -- this round's own brief specifically
required checking this for real rather than guessing from the Ruby
source shape, particularly for `#initialize`'s own `loop do ... end`,
which could have plausibly been the same JMP/JMPNOT `while`/`until`
back-edge shape this compiler has supported since early rounds. It is
not: `loop` is an ordinary `Kernel#loop` *method call* taking a block
(`{ ... }`/`do ... end` is still a block argument to a method, whether
or not that method is a keyword), so mrbc emits `BLOCK`+`SSENDB` for it,
never the `while`/`until` keyword's own inline JMP/JMPNOT compilation.
Confirmed directly against the real generated body -- the whole rest of
`#initialize` (the `s.is_a? String` StringIO-conversion guard and both
`@data`/`@schema` SETIVs immediately before the loop) compiles cleanly
on its own, and the loop itself is the only thing that doesn't:

```
#error unhandled opcode BLOCK -- not in this prototype's supported subset
#error unhandled opcode SSENDB -- not in this prototype's supported subset
```

The private `#sym2idx` (`LCF.elements_of(@schema).each { |k, e| ...
}`) hits the exact same `BLOCK`/`SENDB` pair for the exact same reason
(`Enumerable#each` is a method call taking a block too) -- also
confirmed directly against its own real generated body, not inferred
from the doc comment above `#[]` mentioning it: the @sym2idx
memoization checks, the schema Array/Hash/POLY-fallback GETIDX, and the
final @sym2idx SETIDX around the `.each` block all compile fine on
their own.

`#to_lcf(terminate = true)` and `#respond_to_missing?(sym,
include_private = false)` each report `has non-mandatory arguments
(optional/rest/keyword/block)` -- one optional argument apiece, the
same established gap as every other optional-arg method in this
codebase. (`#to_lcf`'s own `@data.each_with_index do |v, idx| ... end`
body would have hit a second, independent `BLOCK`/`SENDB` gap even past
the arity one, the same shape `#initialize`'s own loop hits above, but
the arity check runs first and is what the diagnostic reports.)
`#method_missing(sym, *args)` reports the same non-mandatory-arguments
reason for its rest argument, same as every other `method_missing` on a
class in this codebase. `attr_reader :schema` stays native/uncompiled,
as always -- not a real bytecode-defined method at all.

**Embedding: none**, confirmed directly against the real diagnostic --
`LCF::Array1D` never appears in bc2cpp's own "classes needing
`MRB_SET_INSTANCE_TT`" listing. `@data` (built via `@data[idx] =
s.read(len)` inside `#initialize`'s own uncompiled loop -- an Array of
Strings) and `@schema` (the constructor's own second argument, a Hash
per its pre-existing `# bc2cpp: (, Hash)` annotation) are never Fixnum/
Symbol, so `IvarLayout` correctly infers nothing embeddable here at
all -- independent of `#initialize` itself never compiling (embedding
only ever happens through a compiling constructor's own SETIV codegen,
so a non-compiling `#initialize` is itself already sufficient to block
embedding, same as every other non-embedding target in this ADR).
`attr_reader :schema` would have mattered here the exact same way it
did for `LCF::EventCommand`'s/`LCF::MoveCommand`'s own `attr_reader`s
above (the eighth severe bug's own trigger shape) if `@schema` were
ever a Fixnum/Symbol embedding candidate -- it isn't, so
`natively_exposed?` never even needs to act on this class; confirmed by
its absence from the `MRB_SET_INSTANCE_TT` listing, not merely inferred
from the ivar's type.

**Verified for real**: this environment's pre-built host `mrbc`
(`/home/user/rpg-maker-clone/build/mruby/host/mrbc/bin/mrbc`, found in
the main checkout's own build tree, one directory over from this
worktree) ran the real `tools/bc2cpp/bc2cpp.rb` against this worktree's
own real `mruby-rpg2k`+`mruby-lcf`+`mruby-rgss` mrblib closed world with
the exact `ONLY_OWNERS`/`NATIVE_SRCS`/`SKIP_UNSUPPORTED` environment
`mruby-lcf-compiled/mrbgem.rake` itself computes (this round's own
`compiled_gems.rb` change adding `LCF::Array1D` to `ONLY_OWNERS`) --
`EXIT: 0` both with `SKIP_UNSUPPORTED=1` (the real build-time mode, used
for the "compiled entry points"/"classes needing `MRB_SET_INSTANCE_TT`"
listings above) and with it unset (used to see each skipped method's
own real `#error` marker, needed to confirm the loop/block reasoning
above rather than guess it). Diffed the regenerated
`lcf_compiled_gen.cpp` against the same run with `LCF::Array1D` left out
of `ONLY_OWNERS`: every diff hunk is a pure addition (confirmed
programmatically, not eyeballed) -- narrowing/widening `ONLY_OWNERS`
never changes any other class's own already-generated code, the same
invariant every prior round's own narrowing check already established.
`g++ -fsyntax-only -std=gnu++17 -Wall -Wextra -Winfinite-recursion`
against the real regenerated file plus the edited `register.cxx` and
the real mruby headers (`3rd/mruby/include` plus the generated
`mruby/presym/id.h` from the same pre-built host tree): **zero errors,
zero `-Winfinite-recursion` warnings**, only the same pre-existing
`-Wunused-but-set-variable`/`-Wunused-parameter`/`-Wunused-function`
noise every prior round already found (the last of those three,
`LCF__File___`/`LCF__File____` defined-but-unused, predates this round
entirely -- `LCF::File#[]`/`#[]=` already compile clean today but were
never wired into this gem's own registration block, a pre-existing,
independent gap this round's own scope did not touch). Compiled
`register.cxx` to a real object file and confirmed with `nm -C`: all
five new `_impl` symbols are present and externally linked (`T`), their
`mrb_get_args` wrappers correctly stay local (`t`). Re-confirmed the
empty-name `mrb_funcall(M, <reg>, "", ` grep against the freshly
regenerated `lcf_compiled_gen.cpp` directly: zero matches. This
environment's own `3rd/mruby`/`3rd/lvgl` submodules are uninitialized
(a fresh-worktree gap, not a code problem), so the real
`cmake`/`rake`-driven engine build and a runtime diff are left for a
correctly-configured checkout, same as every prior round that hit this
exact environment gap.

## Follow-up: second adversarial full-sweep -- `LCF::File#[]`/`#[]=` resolved as real coverage, two confirmed stale-comment drifts (Game::Screen, Game::Transition), no new live bug, two new devirtualization angles checked clean

Not a coverage round: a second dedicated adversarial sweep across
`bc2cpp.rb` itself and all 55 already-shipped owners (`mruby-lcf-
compiled`'s 10, `mruby-rpg2k-compiled`'s 44, `mruby-rgss-compiled`'s 1),
picking up this file's own explicitly flagged open item plus two new
angles this round's own brief named.

**`LCF::File#[]`/`#[]=` resolved: real, previously-missed coverage, not a
stale comment about a genuine limitation.** The immediately preceding
round's own `LCF::Array1D` follow-up had already flagged, in passing,
that `LCF__File___`/`LCF__File____` (the `mrb_get_args` wrappers for
`#[]`/`#[]=`) showed up defined-but-unused in a real `g++` compile even
though `mruby-lcf-compiled/src/register.cxx`'s own top comment and
`mrbgem.rake`'s comment both still claimed the whole `LCF::File`-family
`#[]`/`#[]=` stayed interpreted. Re-ran the real diagnostic directly
against this round's own worktree rather than trusting either comment:
both

```
LCF__File___ / LCF__File____impl  (LCF::File#[], arity 1)
LCF__File____ / LCF__File_____impl  (LCF::File#[]=, arity 2)
```

appear in the real `== compiled entry points ==` listing today, and both
generate the exact same generic Array-fastpath/Hash-fastpath/POLY-
`mrb_funcall`-fallback shape `LCF::Array1D`'s/`LCF::Sections`'s own
already-registered `#[]`/`#[]=` already use (confirmed directly against
the regenerated `lcf_compiled_gen.cpp`: an `if (mrb_array_p(...) &&
mrb_integer_p(...)) { mrb_ary_ref/mrb_ary_set(...) } else if
(mrb_hash_p(...)) { mrb_hash_get/mrb_hash_set(...) } else {
mrb_funcall(M, r3, "[]"/"[]=", ...) }` against `@root`). `LCF::File`'s
own `#initialize` (`mruby-lcf/mrblib/lcf_file.rb`) only ever assigns
`@root` an `LCF::Sections` or an `LCF.const_get(schema[:type])` instance
-- never a genuine Array/Hash -- so the fallback branch always fires at
runtime and dispatches dynamically to whichever real class `@root`
happens to be (`LCF::Array1D` for every non-Array-schema file,
`LCF::Sections` for `LCF::MapTree`'s own Array-schema case); no
devirtualization of `@root` itself is involved, so it never matters which
`LCF::File` subclass (`Database`/`MapTree`/`MapUnit`/`SaveData`) is
actually calling. **Verdict: a real, currently-missed coverage
opportunity, exactly as this round's own brief anticipated as one of the
two possible outcomes -- shipped.** Registered both in
`mruby-lcf-compiled/src/register.cxx`'s own `LCF::File` block and
corrected that file's own top comment plus `mrbgem.rake`'s comment (both
previously listed `#[]`/`#[]=` alongside the genuinely-interpreted
`#initialize`/`#method_missing`/`#respond_to_missing?`/`#save_to`) and
added a matching writeup to `tools/bc2cpp/compiled_gems.rb`'s own
`LCF::File`-family entry. Confirmed the edit itself compiles clean the
same alternate way every prior round without a full LVGL-linked engine
build available already established: `g++ -fsyntax-only -std=gnu++17
-Wall -Wextra -Winfinite-recursion` against the edited `register.cxx`
plus a freshly regenerated `lcf_compiled_gen.cpp` (real host `mrbc`,
exact `ONLY_OWNERS`/`OTHER_OWNERS`/`NATIVE_SRCS` env this gem's own
`mrbgem.rake` computes) -- **zero errors, zero `-Winfinite-recursion`
warnings**; compiled to a real object file and confirmed with `nm -C`:
`LCF__File___`/`LCF__File____` (`t`, local `mrb_get_args` wrappers) and
`LCF__File____impl`/`LCF__File_____impl` (`T`, externally linked) are all
present. Re-confirmed the empty-name `mrb_funcall(M, <reg>, "", ` grep:
zero matches.

**Mechanical re-check of every owner** (does `#initialize` compile and
assign a literal/traceable Fixnum/Symbol to some ivar; does that same
class also carry an `attr_reader`/`writer`/`accessor` or `Struct.new`
member for that exact name; cross-referenced against the real
diagnostic's own "classes needing `MRB_SET_INSTANCE_TT`" list, not just
read from source): re-ran the real whole-program diagnostic against both
gems' full owner sets and grepped every `// @NAME embedded
(fixnum|symbol) -- direct struct field ...` marker `bc2cpp.rb` emits at
every embedded read/write site across the *entire* regenerated output of
both gems (not just `#initialize`) to get the definitive, currently-real
embedded-ivar set per class, rather than trusting any hand-written
comment. Result: **exactly three classes have any real embedded field
today** -- `Game::Transition` (`@width`, `@height` -- 2, not the 5 raw
`EMBED`-proposed candidates), `Game::Screen` (`@flash_r`/`@flash_g`/
`@flash_b`/`@flash_power`/`@flash_strength`/`@flash_total`/`@pan_tx`/
`@pan_ty`/`@fade`/`@fade_target` -- 10, not the raw candidate set),
`RPG2k::Scene::VehicleWorld` (`@type`, a Symbol) -- matching exactly the
three real `MRB_SET_INSTANCE_TT` calls actually present in either
`register.cxx` (`screen`, `transition`, `vehicle_world`) and the three
compiled-owner entries in the diagnostic's own five-item
"classes needing `MRB_SET_INSTANCE_TT`" list (the other two,
`Game::Interpreter`/`RPG2k::Scene::Map::LRUBitmapCache`, are real
embedding candidates that were never added as owners in either gem, the
same standing fact prior rounds already confirmed). No owner among the
other 52 has any embedded field at all, confirmed by the same grep's
absence everywhere else in either 67k-line generated file. This directly
confirms two things: no owner is silently under-protected by
`natively_exposed?` today (an `attr_reader`/`writer`/`accessor`/
`Struct.new` member colliding with something that got embedded anyway
would show up as an extra embedded field on a class with a matching
native accessor -- none does), and the two per-class `register.cxx`
comments below turned out to have drifted anyway, just not by being
*unsafe*.

**Confirmed real: `Game::Transition`'s own registration comment
overstated its embedded set, describing pre-fix behavior.** The comment
claimed all 5 of `@style`/`@frames`/`@width`/`@height`/`@frame` are real
`Game__Transition_ivars` struct fields. The real generated code disagrees
-- `Game__Transition_initialize_impl` writes `@style`/`@frames`/`@frame`
via plain `mrb_iv_set` and only `@width`/`@height` via a real struct-field
write (each still guarded by its own `mrb_integer_p` check), matching the
real `struct Game__Transition_ivars { mrb_int width; mrb_int height; };`
directly. The reason: this class carries a bare `attr_reader :style,
:frames, :frame` (`mruby-rpg2k/mrblib/game.rb`, right above
`#initialize`) -- the exact eighth-severe-bug shape -- so
`natively_exposed?` correctly drops those three from embedding, leaving
only the two names with no native accessor. Confirmed via commit
history, not just inferred, that this is drift rather than a fresh bug:
`Game::Transition`'s own original compile commit (`2f75b9e`, this
environment's clock: 04:57) predates the `natively_exposed?` commit
(`2f35bfa`, 18:00 the same day) that started enforcing this collision
check at all -- so the comment was accurate when written and simply
never revisited once a later, unrelated round's fix silently shrank this
class's own real embedded set. Fixed by rewriting the comment to
describe the real, current 2-field embedded set and explain why the
other three are excluded, cross-referencing this same shape's own
already-documented precedent (the `LCF::MoveCommand` stale-tag finding,
prior round). No `bc2cpp.rb`/generated-code change -- the actual
registration (the `MRB_SET_INSTANCE_TT(transition, ...)` call, still
correctly needed since `@width`/`@height` still embed) and every real
GETIV/SETIV site were already correct; only the comment's claim about
*which* ivars was wrong.

**Confirmed real, larger instance of the same drift: `Game::Screen`'s
own registration comment claimed 21 embedded ivars; only 10 are real
today.** The comment listed `@frames`, `@shake_power`/`@shake_speed`/
`@shake_frames`/`@shake_offset`, `@flash_frames`, `@pan_x`/`@pan_y`/
`@pan_step`, `@fade_frames`/`@fade_transition` as embedded alongside the
10 that really are -- but Screen carries no `attr_reader` at all (its own
embedded fields are read through real bytecode getters, already
correctly noted elsewhere in this same file), so the eighth-severe-bug
shape isn't the cause here. The real cause, confirmed directly against
source rather than assumed: `IvarLayout.analyze` joins a Fixnum/Symbol
type across *every* `SETIV` site for a given ivar name in the whole
class, not just `#initialize`'s own literal ones, and several of these
11 ivars have a second, later write site elsewhere in the same class that
traces to `UNKNOWN` -- `@pan_x = approach(@pan_x, @pan_tx, @pan_step)`/
`@pan_y = approach(...)` in `#update_pan` (a private self-call's opaque
return value -- this is also *why* the class's own doc comment already
says "`@pan_x`/`@pan_y` themselves may sit at a sub-pixel value
mid-pan", unlike `@pan_tx`/`@pan_ty`, which are only ever literal-`0`- or
`h[:key] || default`-assigned and do stay embedded); `@shake_power =
Game.clamp(power, 0, 9)`/`@shake_offset = Game.clamp(newpos, ...)` (a
POLY call's return value); `@shake_frames = frames`/`@frames = frames`/
`@flash_frames = frames` (an opaque mandatory argument, never annotated
or provably Fixnum at every call site); `@fade_transition = style` (same
argument shape); `@pan_step = pan_step_for(speed)` (another opaque
self-call return). This exact fix -- and this exact "Screen loses 11 of
its own previously-'embeddable' ivars" result -- is already correctly
documented elsewhere in this same `register.cxx` file, in the paragraph
describing `IvarLayout.join`'s own UNKNOWN-poisoning fix (several
hundred lines above Screen's own registration block): that paragraph
already names the same 11 ivars and the same before/after counts. The
drift was narrower than it first looks -- not a wrong fact anywhere in
this file, but **two paragraphs in the same file contradicting each
other** (one correctly describing the fix's own history, the other, sitting
in Screen's own registration block where a reader actually looks to see
what Screen embeds today, never updated to match). Fixed the same way as
Transition's: rewrote Screen's own block to state the real 10-field set
directly, explain the general "any other write site can poison an
otherwise-Fixnum-looking ivar" mechanism, and cross-reference the
already-correct fix-history paragraph instead of duplicating a second,
now-stale copy of the same fact. Again, no `bc2cpp.rb`/generated-code
change -- `MRB_SET_INSTANCE_TT(screen, ...)` and every real GETIV/SETIV
site were already correct.

Both fixes verified against the real regenerated `rpg2k_compiled_gen.cpp`
and real mruby headers the same alternate way this environment's
LVGL/SDL2 gap has always required: `g++ -fsyntax-only -std=gnu++17 -Wall
-Wextra -Winfinite-recursion` against the edited `register.cxx` -- **zero
errors, zero `-Winfinite-recursion` warnings**, only the same
pre-existing `-Wunused-but-set-variable`/`-Wunused-parameter` noise every
prior round already found; compiled to a real object file
(`g++ -c -std=gnu++17`) with no additional errors.

**Two new angles checked, both confirmed clean, no fix needed:**

- *Does `ArgTypes.analyze`'s own MONO-name call-site argument-type
  inference have an embedding-style blind spot where a name's sole
  bytecode definition gets shadowed by a same-named native/`attr_*`/
  `Struct.new`-installed method under a different owner, with the wrong
  type getting attributed?* No: `ArgTypes.analyze` (`tools/bc2cpp/
  bc2cpp.rb`) reads the exact same unified `registry` hash `build_registry`
  produces, *after* `NATIVE_SRCS` names are already merged into it (the
  driver's own order, confirmed by reading `bc2cpp.rb`'s `main`-equivalent
  directly: `build_registry` -> the `NATIVE_SRCS`/`extract_native_method_
  names` merge, which flips any name colliding with a native method to
  POLY regardless of owner -> only then `ArgTypes.analyze`), and its own
  first line is `next unless defs.size == 1` -- so any name whose bare
  string collides with *anything* else in the whole program (a
  `NATIVE_SRCS` C/C++ method, an `attr_reader`/`writer`/`accessor`, a
  `Struct.new` member, or a second real bytecode `def`, under the same
  owner or a completely different one) is already POLY in this exact
  registry and is skipped before any inference happens, by construction
  -- there is no way for a "shadowing" definition to arrive after this
  check runs, since the merge that would flip it always runs first.
  Independently, even a wrong inference here is bounded: `arg_types`' own
  only consumer is `IvarLayout.analyze` (confirmed by grepping every use
  of the local `arg_types` -- it never reaches `compile_send` or any other
  codegen path), and every embedded-field SETIV this codegen ever emits
  already carries its own runtime `mrb_integer_p` check plus `mrb_raise`
  regardless of how the type was established (a literal, `ArgTypes`
  inference, or a magic-comment annotation) -- already noted by this
  file's own `Annotations` class comment for exactly this reason. So even
  in a hypothetical case this reasoning missed, the worst outcome is a
  real `TypeError` at runtime, never silent corruption -- outside this
  project's own defined severity bar for a live bug.
- *Does `compile_send`'s own MONO-devirtualization path ever confuse a
  `class << self`/`def self.x`-reopened singleton pseudo-owner
  (`"X.singleton"`, `resolve_singleton_receiver`'s own suffix) with a real
  owner's own instance-method registry entry for the same bare name?*
  Checked directly against the real registry dump for the task's own
  named examples: `:from_page`/`:same_route?` are each `MONO (1 def:
  Game::MoveRoute.singleton)`, `:lower_index` is `MONO (1 def:
  Game::ChipSet.singleton)` -- and the real dump also shows genuine
  instance/singleton bare-name collisions elsewhere in the whole program
  (`:frame` -- 3 defs, `Game::EventGraphic.singleton`/`Game::Transition`/
  `<native>`; `:repeat?` -- 2 defs, `Game::MoveRoute`/`RGSS::Input.
  singleton`; `:active?`, `:load`, `:int_field`, `:row`, `:term`, ... all
  POLY), confirming the registry treats a bare-name collision identically
  regardless of which side is a singleton method and which is a plain
  instance method -- dispatch is purely by flat name, so any such
  collision already forces POLY (never wrongly devirtualizes either
  direction) the same way any other same-name collision does. For the
  non-colliding MONO cases (`from_page`/`same_route?`/`lower_index`,
  genuinely unique names), the real generated output settles the
  question directly: grepped both full regenerated files for `MONO
  :.*\.singleton` and `TYPED :.*\.singleton` -- **zero matches in either
  gem**, confirming no compiled call site anywhere in either gem's real,
  currently-shipped output ever devirtualizes into a `.singleton`-owned
  target. This holds structurally, not by luck: `compile_send`'s own
  `ONLY_OWNERS`/`OTHER_OWNERS` filter (`target = nil if target &&
  @only_owners && !@only_owners.include?(target.owner)` ...) drops any
  target whose owner isn't a registered owner string, and no entry in
  either gem's `BC2CPP_COMPILED_GEMS[...][:owners]` (`tools/bc2cpp/
  compiled_gems.rb`) is ever written with a `.singleton` suffix -- so a
  MONO-but-uncollided singleton method's own real definition is always
  filtered back to ordinary dynamic dispatch before it ever becomes a
  direct call, confirmed directly rather than merely reasoned about
  (`lower_index`'s own 3 real call sites in the regenerated output all
  carry the `// POLY :lower_index -- real dynamic dispatch...` comment,
  even though the registry itself calls the name MONO -- the owner filter,
  not a name collision, is what routes it there). The `TYPED`
  (`trace_new_target`-based) path was checked the same way and can't
  reach a `.singleton` owner either: `known_class` only ever comes from a
  fresh `.new` call's own class expression, an ivar `ClassLayout` hint, or
  a `ClassAnnotations` comment -- none of which ever names a singleton
  pseudo-owner by construction, confirmed by reading `trace_new_target`'s
  own sources directly rather than assumed from the mechanism's shape.
  One structural caveat worth naming rather than silently trusting
  forever: this soundness for the *unguarded* MONO path currently rests
  entirely on no `BC2CPP_COMPILED_GEMS` owners entry ever being written
  with a `.singleton` suffix -- true for all 55 owners today, but a future
  round that added one (to compile a class's own singleton methods
  directly) would need to re-verify this same owner-filter reasoning
  against that new entry specifically, not assume it still holds by
  analogy.

**Also re-checked, no drift found**: every real `MRB_SET_INSTANCE_TT`
call actually present in either `register.cxx` (`screen`, `transition`,
`vehicle_world`) against the diagnostic's own five-item list, the same
cross-check the immediately preceding two rounds already ran -- unchanged,
no sibling of the `LCF::MoveCommand` stale-*call* bug found (this round's
two findings were both stale *field lists inside an otherwise-correct
comment*, not a stale call).

**Verified for real**: both gems' diagnostics were re-run against this
worktree's own real `mruby-rpg2k`+`mruby-lcf`+`mruby-rgss` mrblib closed
world with the exact `MRBC`/`ONLY_OWNERS`/`OTHER_OWNERS`/
`OTHER_DECLS_HEADER`/`NATIVE_SRCS`/`SKIP_UNSUPPORTED` environment each
gem's own `mrbgem.rake` computes, using this environment's pre-built host
`mrbc` (found in the main checkout's own build tree, one directory over
from this worktree, the same "fresh worktree" gap prior rounds already
document and route around rather than rebuild from scratch every round).
Every `g++ -fsyntax-only`/`-c` check above used the real regenerated
output plus the real `3rd/mruby/include` headers and the real generated
`mruby/presym/id.h` from that same pre-built host tree. This environment's
own `3rd/mruby`/`3rd/lvgl` submodules are uninitialized in this worktree
specifically (the same recurring fresh-worktree gap this ADR already
documents many times over), so the final CMake-driven engine link and a
runtime diff are again left for a correctly-configured checkout.

## Follow-up: RGSS::Plane, mruby-rgss-compiled's second owner

A parallel round adds `RGSS::Plane` (`mruby-rgss/mrblib/lib.rb`, right
above `RGSS::Sprite`) as the gem's second owner, alongside the LCF/rpg2k
work covered above. Unlike `Sprite`, `Plane` has no `#initialize` of its
own at all: the native, C++-side `#initialize` (`mruby-rgss/src/lib.cxx`)
never sets the ivars this class's own Ruby-level methods read, so all 6
of its own real bytecode-defined methods -- `#opacity`, `#zoom_x`,
`#zoom_y`, `#blend_type`, `#tone`, `#color` -- are plain readers falling
back to RGSS defaults (`@opacity.nil? ? 255 : @opacity`, `@blend_type ||
0`, `@tone ||= Tone.new(0, 0, 0, 0)`, ...), the exact same shape
`Sprite`'s own already-shipped methods of the same names already use.
`attr_reader :bitmap, :ox, :oy, :z, :viewport` stays native/uncompiled,
as always.

All 6 compile clean, confirmed directly against the real `==
compiled entry points ==` listing, needing zero new opcode work: `||=`
needs no dedicated opcode at all (mrbc lowers it to a plain
GETIV/JMPIF-guarded-GETCONST+SEND+SETIV sequence, already exercised by
`Sprite`'s own identical `@tone ||=`/`@color ||=` methods).

Embedding: none. `drop_unsafe_embeddings`'s own class-level gate requires
a *compiling* `#initialize` with pure mandatory arity before embedding
anything on a class at all -- `Plane` has no `#initialize` (compiling or
otherwise), so nothing on it is ever even proposed as an embedding
candidate, confirmed directly: `RGSS::Plane` never appears in bc2cpp's
own "classes needing `MRB_SET_INSTANCE_TT`" diagnostic. Verified via a
real `g++ -fsyntax-only -std=gnu++17 -Wall -Wextra -Winfinite-recursion`
compile against the regenerated `rgss_compiled_gen.cpp` plus the edited
`register.cxx` (the established fallback for this gem, since a full
LVGL-linked build isn't always available in every environment): zero
errors, zero `-Winfinite-recursion` warnings. Empty-method-name grep
against the regenerated file: zero matches.

## Follow-up: LCF::Array2D, LCF::Array1D's structurally different sibling

A parallel round adds `LCF::Array2D` (`mruby-lcf/mrblib/lcf.rb`, right
below `LCF::Array1D`) -- the id-keyed table of rows every `LCF::File`
-family object's own project-map tree / database item/actor/skill/...
list actually decodes through, each row itself an `Array1D` chunk stream
decoded lazily. Confirmed by reading the real source rather than assumed
identical to its sibling: 6 real bytecode-defined methods, not 11, and
neither `#method_missing` nor `#respond_to_missing?` exists on this class
at all (rows are indexed purely by integer id, with no per-field symbolic
accessor to dispatch through).

Only 2 of the 6 compile clean, confirmed directly against the real `==
compiled entry points ==` listing: `#[]` (lazily decodes and in-place
caches a row's raw byte span into a real `Array1D.new(entry, @schema)` on
first access) and `#[]=` (a bare `@data[idx] = entry` SETIDX). The other
4 stay interpreted, each confirmed against its own real `#error` marker
rather than guessed from the Ruby source shape: `#initialize`'s own
`(0...LCF.read_ber(s)).each do ... end` is a `Range#each` call taking a
block -- a different block-taking method than `Array1D#initialize`'s own
`Kernel#loop`, but the identical `BLOCK`/`SENDB` opcode gap; `#each`'s own
`@data.size.times do |i| ... end` hits the same pair a third way;
`#to_lcf` (no arguments, unlike `Array1D#to_lcf`'s own optional argument)
hits the pair twice independently; and the private `#read_row_bytes` has
a real `loop do ... end`, the same shape as `Array1D#initialize`'s own
loop.

Embedding: none. `@data` (an Array, holding raw byte-span Strings until
lazily replaced by decoded `Array1D` instances) and `@schema` (a Hash)
are never Fixnum/Symbol, and this class carries no `attr_reader`/
`attr_writer`/`attr_accessor` at all (unlike `Array1D`'s own `attr_reader
:schema`), so there is no native-accessor/embedded-ivar collision surface
here for `natively_exposed?` to act on -- confirmed directly: `LCF::Array2D`
never appears in bc2cpp's own "classes needing `MRB_SET_INSTANCE_TT`"
diagnostic. Verified via the established `g++ -fsyntax-only -std=gnu++17
-Wall -Wextra -Winfinite-recursion` fallback against the regenerated
`lcf_compiled_gen.cpp` plus the edited `register.cxx`: zero errors, zero
`-Winfinite-recursion` warnings. Empty-method-name grep against the
regenerated file: zero matches.

## Follow-up: RGSS::Window, mruby-rgss-compiled's third owner, and a new "alias_method is invisible to build_registry" registry gap

A parallel round adds `RGSS::Window` (`mruby-rgss/mrblib/lib.rb`, line
1019) as the gem's third owner. Unlike `Sprite`/`Plane`, `Window` mixes
many plain zero-argument readers with a real, optional-argument
`#initialize` and an `alias_method` call, read in full from the real
source rather than assumed from a summary: `attr_reader :contents,
:windowskin, :x, :y, :width, :height, :ox, :oy, :z, :viewport,
:contents_opacity` (native/uncompiled, as always), then 12 real
bytecode-defined methods, then `alias_method :_rgss1_initialize,
:initialize` immediately followed by a redefined `#initialize(x = nil, y
= nil, width = nil, height = nil)`.

All 12 non-`#initialize` methods compile clean, confirmed directly
against the real `== compiled entry points ==` listing and the real
generated bodies: `#opacity`/`#back_opacity`/`#active`/`#stretch`/
`#openness` (`@ivar.nil? ? default : @ivar`) and `#pause`
(`@pause || false`) reuse the exact nil-guarded-default/`||` shape
`Sprite`/`Plane` already established; `#cursor_rect` (`@cursor_rect ||=
Rect.new(0, 0, 0, 0)`) reuses the `||=` + owner-scope-first-GETCONST
shape already proven by `Sprite`'s own `@tone ||=`/`@color ||=`; and
`#padding`/`#arrows_visible` repeat the nil-guarded-default shape once
more. The three same-class self-call methods this task specifically
flagged for direct verification all confirm the expected MONO
devirtualization rather than an ordinary `mrb_funcall`, checked against
the real regenerated bodies, not assumed from the Ruby source shape:
`#open?`'s `openness == 255` and `#close?`'s `openness.zero?` each carry
a `// MONO :openness -> RGSS::Window#openness, direct C++ call (no
mrb_funcall)` comment followed by a direct `RGSS__Window_openness_impl(M,
self)` call, and `#padding_bottom`'s `@padding_bottom.nil? ? padding :
@padding_bottom` carries the matching `// MONO :padding ->
RGSS::Window#padding, direct C++ call` comment followed by a direct
`RGSS__Window_padding_impl(M, self)` call -- the identical mechanism
already exercised for every other same-owner self-call in this whole
program, needing zero new bc2cpp.rb work.

`#initialize` does **not** compile, confirmed directly against the real
`#error` marker rather than assumed from its 4 optional arguments:
`#error RGSS::Window#initialize has non-mandatory arguments
(optional/rest/keyword/block) -- not in this prototype's supported
subset`, the exact same `pure_mandatory_arity?` gap every other
optional-argument `#initialize` in this codebase already hits (this
one's own arity check fires unconditionally on the method's signature,
before any of its own SEND instructions -- including the `_rgss1_
initialize`/`self.x=`/`self.y=`/... calls inside its `if`/`elsif`/`else`
body -- are ever inspected).

The `alias_method :_rgss1_initialize, :initialize` line right before it
is a genuinely new shape for this ADR, checked directly rather than
assumed to behave like `class << self`/`def self.x` (this compiler's
fifth severe-bug fix, an earlier follow-up above) or like a native
method: `alias_method` is a plain self-implicit method call -- it
compiles to an ordinary `SSEND :alias_method n=2` instruction, confirmed
by disassembling an isolated repro with the real `mrbc -v -S` (two
`def initialize`s each get their own `TDEF R1 :initialize I[n]`; the
`alias_method` line between them lowers to `LOADSYM`/`LOADSYM`/`SSEND
:alias_method n=2`, no dedicated opcode of its own) -- a wholly
different mechanism than the Ruby *keyword* `alias new_name old_name`,
which has its own dedicated `OP_ALIAS` bytecode instruction bc2cpp.rb
does not reference anywhere either, but which at least carries a static,
scannable operand naming both symbols; `alias_method`'s aliasing effect
instead happens purely at runtime, inside the ordinary Kernel method
call, with no bytecode operand naming the new method at all.
`build_registry` populates its whole name -> definitions map exclusively
by walking `TDEF`/`DEF` pairs (`walk`'s own `CLASS`/`MODULE`/`SCLASS`+
`EXEC` and `TCLASS`/`METHOD`+`DEF` handling), so `_rgss1_initialize`
never becomes a registry key under any owner, confirmed directly: both
the full registry dump (`== native method names ==`'s neighboring
MONO/POLY listing) and the fully regenerated `rgss_compiled_gen.cpp`
were grepped for `_rgss1_initialize` and `rgss1` -- zero matches in
either, anywhere in this closed world.

This is a **third**, structurally distinct cause of registry-invisibility
alongside the two this ADR already documents for other reasons: a native
method (defined in `.cxx`, no Ruby-level `TDEF` at all) is scraped back
in from `NATIVE_SRCS` by a dedicated `extract_native_method_names` regex
pass, and a `class << self`/`def self.x` singleton method gets a real
`DEF` of its own, just filed under a synthesized `"Owner.singleton"`
pseudo-owner key (`resolve_singleton_receiver`) rather than being
missing. `alias_method` has no equivalent backfill of any kind on either
side -- the aliased name is not mis-filed under the wrong owner the way
an unguarded singleton devirtualization once could have been, it is
simply never written to the registry at all, under any owner, so
`compile_send` can only ever see 0 definitions for it and fall back to
ordinary dynamic `mrb_funcall` dispatch -- never a wrong devirtualization
of some unrelated same-name method, just a permanently missed
optimization. Confirmed not currently exploitable as a live bug: the
only real call site for `_rgss1_initialize` anywhere in this closed world
is `RGSS::Window#initialize`'s own body, and that body's own SEND
instructions are never reached by `compile_send` at all, because the
non-mandatory-arity `#error` above fires first and drops the whole
method before any of its sends are inspected. Flagged here, per this
round's task, as a real general gap for whoever next adds an
`alias_method`-defined name with a live, actually-compiling call site
elsewhere in the program: under this prototype's own severity bar, a
silent fallback to dynamic dispatch is always safe (the interpreter
still runs the real aliased method correctly; only a devirtualization
opportunity is lost), so this is a documented missed optimization, not a
correctness risk -- but it is worth a real fix (teaching `build_registry`
to recognize a self-implicit `SEND/SSEND :alias_method` with two literal
Symbol arguments and register the new name as a synonym for the old
name's own definition list) the next time a round's target class relies
on `alias_method` for a method whose *aliased* name is itself called
from a call site that would otherwise compile.

Embedding: none, confirmed directly against the real diagnostic rather
than assumed from `#initialize` not compiling: `RGSS::Window` never
appears in bc2cpp's own "classes needing `MRB_SET_INSTANCE_TT`" listing.
`drop_unsafe_embeddings`'s own class-level gate requires a *compiling*
`#initialize` with pure mandatory arity before embedding anything on a
class at all -- `#initialize` here fails that gate outright, so nothing
on `RGSS::Window` (not even the always-nil-guarded `@padding`/
`@arrows_visible`/... ivars the 12 compiling readers touch) is ever even
proposed as an embedding candidate.

Verified via the established `g++ -fsyntax-only -std=gnu++17 -Wall
-Wextra -Winfinite-recursion` fallback (this gem's own real build still
depends on a built LVGL this environment's worktree doesn't have) against
the regenerated `rgss_compiled_gen.cpp` (built with the real `SKIP_
UNSUPPORTED=1` this gem's own `mrbgem.rake` sets, which drops the
`#initialize` `#error` entry from the emitted file entirely rather than
leaving a literal `#error` preprocessor directive in it) plus the edited
`register.cxx`: zero errors, zero `-Winfinite-recursion` warnings (only
the same pre-existing, unrelated `-Wunused-but-set-variable` noise on
`Sprite`/`Plane`'s own already-shipped register-numbered locals that
predates this round). Empty-method-name grep (`mrb_funcall(M,
[a-z0-9]*, "", `) against the regenerated file: zero matches.

## Follow-up: RGSS::Tilemap, and a real cross-check of the owner-scope-first GETCONST fix against a bare core-class name

Adds `RGSS::Tilemap` (`mruby-rgss/mrblib/lib.rb`, right above `RGSS::Window`)
as `mruby-rgss-compiled`'s third owner, alongside the already-shipped
`RGSS::Sprite`/`RGSS::Plane`. It is an even smaller target than Plane:
`attr_reader :tileset, :map_data, :ox, :oy, :viewport, :priorities,
:flags` and `attr_accessor :flash_data` stay native/uncompiled as
always, leaving exactly one real bytecode-defined method, `#autotiles`
(`@autotiles ||= Array.new(7)`, RGSS's own fixed 7-slot autotile table).
Confirmed directly against the real `== compiled entry points ==`
listing: adding `RGSS::Tilemap` to `ONLY_OWNERS` adds exactly one new
line (`RGSS__Tilemap_autotiles`, arity 0) and changes nothing already
shipped.

`#autotiles`'s own `||=` needs no new opcode work -- the same
GETIV/JMPIF-guarded-GETCONST+SEND+SETIV lowering already verified for
Sprite's/Plane's own `@tone ||=`/`@color ||=`. But this round's own task
explicitly called for checking, not assuming, that the owner-scope-first
GETCONST fix (this ADR's own RGSS::Sprite follow-up) resolves a bare
*core* class name the same way it resolves an RGSS-namespaced one, since
`Array` (unlike `Tone`/`Color`/`Rect`) is not nested under `RGSS` at
all -- it lives directly on `Object`. Read the real regenerated body
rather than inferring from Plane's own success:

```c
{
  mrb_value scope0 = mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, "RGSS"));
  mrb_value scope1 = mrb_const_get(M, scope0, mrb_intern_cstr(M, "Tilemap"));
  mrb_bool ok = FALSE;
  mrb_value r2_tmp = mrb_nil_value();
  if (!ok) r2_tmp = bc2cpp_const_try(M, scope1, mrb_intern_cstr(M, "Array"), &ok);
  if (!ok) r2_tmp = bc2cpp_const_try(M, scope0, mrb_intern_cstr(M, "Array"), &ok);
  if (!ok) r2_tmp = mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, "Array"));
  r2 = r2_tmp;
}
```

This is a real, meaningfully different path than Plane's own
`Tone`/`Color` lookups, not just the same shape reapplied: those matched
at the *first* protected `bc2cpp_const_try` scope (`RGSS`, since `Tone`/
`Color` are really `RGSS::Tone`/`RGSS::Color`). `Array` matches at
*neither* protected scope -- `RGSS::Tilemap` and `RGSS` both fail to
define their own `Array` -- and only resolves at the chain's final,
unprotected `mrb_const_get` against `M->object_class`, exactly the
"top-level fallback" case the original GETCONST codegen comment already
documents for a bare `Object`-owned `def`, just reached here via the
multi-scope chain instead of the single-scope one. Same resulting
`Array.new(7)` semantics either way -- confirmed real, not assumed
identical merely because the `||=` shape matches.

Embedding: none. `RGSS::Tilemap` has no `#initialize` of its own at all
(the exact same shape as `Plane`), so `drop_unsafe_embeddings`'s own
class-level gate excludes it from consideration outright, independent of
ivar type -- confirmed directly against the real diagnostic: it never
appears in bc2cpp's own "classes needing `MRB_SET_INSTANCE_TT`" listing
(5 classes total this round, none of them `RGSS::Tilemap`).
`@autotiles` picks up a `CLASS_HINT` (`Array`) from its own `||=`
construction, exactly like Plane's `@tone`/`@color` picking up `Tone`/
`Color`, but a `CLASS_HINT` alone never embeds without a compiling
constructor either.

**Verified for real:** the real, opt-in `RPGMAKER_BC2CPP=1` +
`rake -f 3rd/mruby/Rakefile` pipeline was attempted end to end in this
worktree and hit the same two environment gaps this ADR's own
`Game::Rng`/`Game::Troop`/`RPG2k::Scene::VehicleWorld` follow-ups already
document: the `3rd/mruby`, `3rd/mruby-marshal`, `3rd/mruby-onig-regexp`,
`3rd/mruby-stringio`, `3rd/uni-algo`, and `3rd/stb` submodules were
uninitialized in this fresh worktree (fixed with a plain
`git submodule update --init`, kept out of this round's own diff, same
as every prior round's own practice), and, once past that, the pipeline
still hit the real `mruby-rgss`/LVGL final-link gap (`mruby-rgss/src/
lib.cxx` needs a real built `lvgl.h`, which a raw `rake -f
3rd/mruby/Rakefile` invocation has no step to build). This round also
hit a real, previously-undocumented third setup gap on the way to the
established `g++ -fsyntax-only` fallback: a bare `rake -f
3rd/mruby/Rakefile MRUBY_BUILD_DIR=...` run from *this* worktree's own
root resolves `MRuby::Build.mruby_config_path` to the project's own root
`build_config.rb` rather than `3rd/mruby`'s `build_config/default.rb`
(`Dir.pwd != MRUBY_ROOT && File.file?("./build_config.rb")` -- true for
any invocation from the project root, `MRUBY_CONFIG` unset or not), so
it pulls in every RPG Maker gem, `mruby-lcf`'s `cp932_table` env-var
requirement included, well before a plain host `mrbc` is needed at all.
Building the host `mrbc` alone therefore has to run `rake` from inside
`3rd/mruby` itself (`Dir.pwd == MRUBY_ROOT`, so `mruby_config_path` falls
through to the plain `build_config/default.rb` gembox, no RPG Maker gems
and no `cp932_table` involved) -- confirmed against the real
`lib/mruby/build.rb` source rather than assumed. That build config also
defaults to a plain `gcc` linker command, which fails at the final link
step with undefined `__cxa_*` C++-exception-runtime references (this
project's own core `vm.c`/`vm-cxx.cxx` is built with `MRB_USE_CXX_
EXCEPTION`, needing a C++ linker driver) -- root `build_config.rb`'s own
comment (`conf.cc.command = ENV['HOST_CC'] || 'cc'` /
`conf.linker.command = ENV['HOST_CXX'] || 'c++'`) documents the fix this
round applied: `HOST_CXX=c++` (linker only, kept `HOST_CC` as the plain C
compiler `cc` -- forcing the *compiler* itself to `g++` for `.c` sources
instead miscompiles `src/fmt_fp.c`'s own `mrb_format_float` with C++
name-mangled linkage, a real, checked-not-assumed second-order bug this
round hit and back out of, since `numeric.c` calls it expecting plain C
linkage from `mruby.h`'s own `extern "C"` wrapper). With both fixes, a
real host `mrbc` (`mruby 4.0.0`) built clean.

Ran `tools/bc2cpp/bc2cpp.rb` directly against that real host `mrbc`
(`ONLY_OWNERS`/`OTHER_OWNERS`/`NATIVE_SRCS` computed exactly the way
`mruby-rgss-compiled/mrbgem.rake` does, `SKIP_UNSUPPORTED=1`) over the
whole `mruby-rpg2k`+`mruby-lcf`+`mruby-rgss` closed world -- the real
`== compiled entry points ==` and "classes needing
`MRB_SET_INSTANCE_TT`" listings quoted above came from that real run,
not simulated. Grepped the real regenerated `rgss_compiled_gen.cpp` for
the broken empty-name `mrb_funcall(M, <reg>, "", ` shape: zero matches.
`g++ -fsyntax-only -std=gnu++17 -Wall -Wextra -Winfinite-recursion`
against the real edited `register.cxx` plus that real generated file and
the real mruby headers (`3rd/mruby/include`, the real generated `mruby/
presym/id.h` from the plain host `mrbc` build above -- `register.cxx`
and the generated file both resolve method/ivar names through plain
`mrb_intern_cstr` at runtime, never a compile-time `MRB_SYM`-family
macro, so this presym table's own gembox-specific symbol set doesn't
need to match the real project's for this check to be valid): **zero
errors, zero `-Winfinite-recursion` warnings** (only the same
pre-existing, harmless `-Wunused-but-set-variable` warnings every other
compiled method here already has, `RGSS::Tilemap#autotiles` included).
Compiled `register.cxx` to a real object file and confirmed with
`nm -C`: `RGSS__Tilemap_autotiles_impl` is present and externally linked
(`T`), its `mrb_get_args` wrapper `RGSS__Tilemap_autotiles` correctly
stays local (`t`), and `RGSS::Tilemap` appears in no embedding-struct
symbol set at all, confirming the embedding-none conclusion directly
rather than assuming it: no `RGSS__Tilemap_ivars` struct, no
`MRB_SET_INSTANCE_TT` call, and the one compiled method reads/writes
`@autotiles` through the ordinary dynamic `iv_tbl`.

## Follow-up: a dedicated cross-gem-devirtualization-soundness sweep -- one real drift-risk fix, one documentation-accuracy fix, no new live bug, MRB_SET_INSTANCE_TT re-confirmed clean

A dedicated bug-hunt round, explicitly *not* a coverage round, targeting
three angles this ADR's own history had never specifically audited:
whether the two (now three) compiled gems' independent `bc2cpp.rb`
invocations could disagree about a name's true whole-program MONO/POLY
status; whether every already-shipped "stays interpreted due to a
`rescue` clause" comment actually names the real, complete reason; and a
plain re-diff of the `MRB_SET_INSTANCE_TT` diagnostic against both
`register.cxx` files now that the owner count has grown to 59 across
three gems (`mruby-lcf-compiled`, `mruby-rpg2k-compiled`,
`mruby-rgss-compiled`).

**Angle 1: cross-gem devirtualization soundness.** This ADR's own
earlier follow-up ("cross-gem devirtualization") built the whole
mechanism (dropping `_impl`'s own `static`, `OTHER_OWNERS`/
`OTHER_DECLS_HEADER`, `emit_decls_header`) and verified it end to end,
but at the time only two gems existed with 2 non-overlapping owners
total, and it found "no real cross-gem devirtualized call actually
appears in either shipped target's own output" -- a mechanism verified
sound with nothing yet to bite into. This round re-ran that same
question for real against the *current* 59-owner, three-gem program,
not by re-reading that old conclusion and assuming it still holds.

Structural check first: each of the three `mrbgem.rake` files feeds
`bc2cpp.rb` an identical whole-program `closed_world_srcs` (every one of
`mruby-rpg2k`/`mruby-lcf`/`mruby-rgss`'s own `mrblib`, confirmed
byte-identical across all three files' own literal `Dir[...]`
expressions before this round touched them) and an identical
`NATIVE_SRCS` (`mruby-rgss/src/*.cxx` plus `core_native_srcs`). Since
`build_registry`'s own MONO/POLY resolution is a pure function of that
input, and all three invocations feed it the exact same input, the
three gems' own registries are *structurally guaranteed* to reach the
same MONO/POLY conclusion for any given name -- not merely observed to
agree today. `ONLY_OWNERS`/`OTHER_OWNERS` (`compile_send`'s own guard,
`target && @only_owners && !@only_owners.include?(target.owner) ->
target = nil unless @other_owners&.include?(target.owner)`) then only
gates *emission*, never registry construction, and a real check
confirmed the three gems' owner lists (`BC2CPP_COMPILED_GEMS`) are
disjoint (59 unique owners, zero duplicates) -- so `only_owners ∪
other_owners` always equals the full 59-owner set from every one of the
three invocations' own point of view.

**A real, previously-unenforced drift risk, fixed.** Unlike
`BC2CPP_COMPILED_GEMS` (owners) and `core_native_srcs` (native names),
both already centralized in `tools/bc2cpp/compiled_gems.rb` specifically
to remove this class of risk, `closed_world_srcs` was still three
separate hand-typed `Dir[...] + Dir[...] + Dir[...]` literals, one
per `mrbgem.rake`. Confirmed byte-identical today, but nothing enforced
that: a future round adding a fourth mrblib directory to the closed
world (or reordering/typo'ing one of the three) could edit one or two
files and miss the third, with **no build error at all** -- Rake has no
way to notice that gem A's own registry now sees a different whole
program than gem B's, silently reintroducing exactly the soundness gap
`OTHER_OWNERS`/`OTHER_DECLS_HEADER` exists to close. Fixed by extracting
a new `closed_world_mrblib_srcs(gems_root)` into `compiled_gems.rb`
(mirroring `core_native_srcs`'s own shape) and pointing all three
`mrbgem.rake` files at it instead of their own inlined literal. Verified
mechanical, not behavioral: `closed_world_mrblib_srcs("#{dir}/..")`
returns the exact same array (`==`, checked directly) as the literal it
replaced, and a real, full `bc2cpp.rb` run for all three gems (their own
`ONLY_OWNERS`/`OTHER_OWNERS`/`NATIVE_SRCS`/`SKIP_UNSUPPORTED=1`
reproduced exactly, against this worktree's own real `mrblib` source and
a real host `mrbc`) before and after this refactor produced
byte-identical generated output in all three files (the only diff being
the `OUT_DIR`-specific path string inside each run's own scratch
directory's `#include` line, an artifact of running the same script
twice into two different output directories, not of the refactor).

**Then the real question: does any live call site actually cross a
gem boundary today?** Ran all three gems' real `bc2cpp.rb` invocations
(env reproduced exactly from each `mrbgem.rake`, including the full,
real `NATIVE_SRCS` -- 545 names, 39 flipped MONO-to-POLY, matching this
ADR's own established scale, not the ~150/19 a first pass got from an
freshly-cloned worktree's uninitialized `3rd/mruby` submodule; caught
and fixed with the same plain `git submodule update --init` this ADR's
own prior round already established as standard practice before trusting
any diagnostic number from a fresh worktree) and grepped every `MONO`/
`TYPED` devirtualization comment in all three generated files for a
target whose owner isn't that file's own gem. Every single one --
`Game::*`/`RPG2k::*`/`RPG2k3::Scene::Battle` targets inside
`rpg2k_compiled_gen.cpp`, `RGSS::Window` inside `rgss_compiled_gen.cpp`,
none at all inside `lcf_compiled_gen.cpp` -- stays within its own gem's
owner set. **Zero real cross-gem devirtualized calls exist in the
current build**, the same "mechanism verified sound, nothing to bite
into yet" result as the original follow-up, now re-confirmed at nearly
30x the owner count.

The closest real near-miss, checked directly rather than left to
inference: `LCF::Array1D` (an `mruby-lcf-compiled` owner) defines
`#delete`, and three `mruby-rpg2k-compiled` methods call `.delete` on an
ivar that is plausibly an `Array1D` at runtime -- `Game::Actor
#forget_skill`'s `@skills.delete(skill_id)` (this tool's own long-
standing README example), `Game::Battle#cure_state`, and `Game::Party
#promote_to_leader`. With the full, real `NATIVE_SRCS` in place, `:delete`
correctly comes back `POLY (2 defs: LCF::Array1D, <native>)` in the
registry dump (`FLIP :delete` logged) -- colliding with core `Array#
delete`/`Hash#delete`, the exact same already-fixed gap this ADR's own
"mruby core native method registry extraction" follow-up named -- so all
three call sites correctly compile to ordinary `mrb_funcall(M, r, "delete",
1, ...)` POLY dispatch, confirmed directly in the regenerated
`rpg2k_compiled_gen.cpp`, not a MONO direct call into `LCF::Array1D`'s
own `_impl`. (The first, submodule-incomplete pass above did show a
false-positive `MONO :delete -> LCF::Array1D#delete, direct C++ call` at
all three sites -- an artifact of that pass's own incomplete `NATIVE_SRCS`
missing the entire core collision list, not a real bug in this project;
included here only as the concrete reason this round re-ran the check
with the submodule properly initialized before trusting the result, the
same lesson this ADR's own `RGSS::Tilemap` follow-up already logged.)

**Angle 2: does every "stays interpreted due to a `rescue` clause"
comment name the real, complete reason?** Checked a representative
sample against each one's own real generated `#error` markers rather
than trusting the existing prose: `RPG2k::Scene::SaveLoad#load_face_
bitmap`/`#slot_timestamp`, `RPG2k::Scene::SkillMenu#load_face_bitmap`/
`#play_skill_sound_effect`, `RPG2k::Scene::ChipsetEditor#save_to_disk`,
and all four of `RPG2k::Scene::Base`'s own rescue-tagged methods
(`#make_windowskin`, `#play_system_se`, `#screen_width`,
`#screen_height`). Every one of these hits exactly the documented
`EXCEPT`/`RESCUE`/`RAISEIF` triple and nothing else -- the existing
comments are accurate for all of them.

**One was not: `RPG2k::Scene::DebugMenu#open_map_viewer`.** The existing
comment (in `docs/adr/0139` itself, `tools/bc2cpp/compiled_gems.rb`, and
`mruby-rpg2k-compiled/src/register.cxx`, all three) named only "a real
`begin ... rescue StandardError => e ... end` (RESCUE/RAISEIF/EXCEPT)".
Real, but incomplete: the method's real source is `if @state.map && ...
then @parent.push Scene::MapViewer.new(@parent, @state, map:
@state.map); return else map = begin @parent.load_map(@map_id) rescue
StandardError => e ... end; ...; end` -- an `if`/`else` with one
independent gap *per branch*. The `else` branch really does hit `EXCEPT`/
`RESCUE`/`RAISEIF`, confirmed directly. But the `if` branch's own
`Scene::MapViewer.new(@parent, @state, map: @state.map)` hits a
completely different, unrelated gap *first* (earlier in program order,
in the branch actually taken when the current map is already loaded):
`#error SEND/SSEND :new has a splat and/or keyword argument list (n=2|
nk=1)` -- the exact opcode-shape this ADR's own third-severe-bug
follow-up (the silently-dropped-keyword-argument bug) already named and
fixed at the root in `compile_send`. Both gaps are independently real
and independently already-established out-of-scope shapes -- neither is
new, and nothing about this method was ever silently miscompiled (both
correctly emit `#error` and the whole method correctly falls back to
the interpreter under `SKIP_UNSUPPORTED=1`). The only real problem was
the comment naming just one of the two: read at face value, it implies
a future round adding real `RESCUE`/`RAISEIF`/`EXCEPT` opcode support
would unlock this method the way the ADR's own text already speculates
for `RPG2k::Scene::ItemMenu`/`DebugMenu`/`Menu`'s own shared `SUPER`
gap -- but it would not, since the `if` branch's own keyword-argument
call site would still block it. Fixed all three comments to name both
gaps and their exact branch.

**Angle 3: a fresh `MRB_SET_INSTANCE_TT` re-diff.** Re-ran the real
whole-program diagnostic (no `ONLY_OWNERS`, full `NATIVE_SRCS`) against
the current 59-owner closed world. "Classes needing
`MRB_SET_INSTANCE_TT(..., MRB_TT_DATA)`": `Game::Transition`,
`Game::Screen`, `Game::Interpreter`, `RPG2k::Scene::VehicleWorld`,
`RPG2k::Scene::Map::LRUBitmapCache`. Of these, `Game::Interpreter` and
`RPG2k::Scene::Map::LRUBitmapCache` are not compiled owners at all (no
entry in `BC2CPP_COMPILED_GEMS`), so correctly have no registration
anywhere. The other three all have a real `MRB_SET_INSTANCE_TT` call,
confirmed by grepping both `register.cxx` files directly:
`mruby-rpg2k-compiled/src/register.cxx` has `MRB_SET_INSTANCE_TT(screen,
MRB_TT_DATA)`, `MRB_SET_INSTANCE_TT(transition, MRB_TT_DATA)`, and
`MRB_SET_INSTANCE_TT(vehicle_world, MRB_TT_DATA)`. **Clean -- no drift
found**, this round's own three added owners (`RGSS::Window`/
`RGSS::Tilemap` from the parallel RGSS round merged in just before this
sweep, plus the accumulated 59-owner total) included.

**Net result of this round:** one real, previously-unenforced structural
drift risk closed (`closed_world_mrblib_srcs`, zero behavioral change,
confirmed byte-identical generated output before/after across all three
gems); one real documentation-accuracy fix (`#open_map_viewer`'s own
two-gap comment, three locations); angle 3 re-confirmed clean. No new
live miscompilation bug found -- the closest candidate (the submodule-
incomplete false-positive `:delete` cross-gem MONO) was a defect in this
round's own first test pass, not in the project, and was caught and
discarded before being reported as one.

## Follow-up: RGSS::Bitmap, and a genuinely new finding -- an `SDEF` (`def self.x`) singleton method is registered for MONO/POLY soundness but can never itself be a compile target, independent of its own body

Adds `RGSS::Bitmap` (`mruby-rgss/mrblib/lib.rb`, right below
`RGSS::Window`) as `mruby-rgss-compiled`'s fifth owner. This is a
noticeably larger and more varied target than any of the gem's first
four: a nested `LoadError` exception class, a real `#initialize` with an
optional second argument *and* real `.each`-with-block logic past its own
arity gate, a `def self.x` singleton method, and a private helper ending
in `rescue`. Read the real class body directly (lines 611-761) rather
than trusting a summary of it, per this round's own task framing -- and
one part of that summary's own premise turned out to be wrong once
checked against the real diagnostic (below).

Only 2 of `RGSS::Bitmap`'s own real bytecode-defined methods compile
clean, confirmed directly against the real `== compiled entry points ==`
listing: `#font` (`@font ||= Font.new`) and `#font=` (`@font = f`).
`#font`'s own `||=` needs no new opcode work -- the same
GETIV/JMPIF-guarded-GETCONST+SEND+SETIV lowering already verified for
Sprite's/Window's own `@tone ||=`/`@cursor_rect ||=`, `Font` resolving at
the `RGSS` scope exactly like `Tone`/`Color`/`Rect` before it (the first
protected `bc2cpp_const_try` scope, not the unprotected top-level
fallback `Array` needed in the `RGSS::Tilemap` follow-up immediately
above). `#font=` is a plain one-argument `SETIV` setter, confirmed clean
with zero opcode surprises.

**`#initialize(f, s = nil)`** has one real optional argument, hitting the
same `pure_mandatory_arity?` gate `RGSS::Window#initialize` already hits
(`#error RGSS::Bitmap#initialize has non-mandatory arguments
(optional/rest/keyword/block) -- not in this prototype's supported
subset`), confirmed directly against the real generated output before
`SKIP_UNSUPPORTED=1` drops it. Its own real `[GAME_DIR,
RTP_DIR].each do |d| ... end` block logic past that gate is never even
reached by codegen -- the non-mandatory-arity `#error` fires first and
unconditionally, the same "gate fires before the body is ever inspected"
shape this ADR's own `RGSS::Window`/`alias_method` follow-up already
established for a different method.

**The private `#init_from_archive(f, s)`** has pure mandatory arity (2
args) but its own real body hits three distinct unsupported opcodes in
sequence -- confirmed via its own real markers rather than assumed to be
simply "the same rescue gap" other classes hit: `Bitmap.extensions.each
do |ext| ... end` (a real block argument) emits `#error unhandled opcode
BLOCK` immediately followed by `#error unhandled opcode SENDB` -- both
*before* codegen ever reaches this method's own trailing `rescue
StandardError => e ... end`, which separately emits `#error unhandled
opcode EXCEPT` then `#error unhandled opcode RESCUE`. The `.each` block is
the actual first gap this method hits, not the rescue clause alone --
this round's own task explicitly asked for the real marker rather than an
assumed match to the established rescue/RAISEIF/EXCEPT gap, and the real
marker turned out to name a second, independent unsupported opcode pair
ahead of it.

**The nested `RGSS::Bitmap::LoadError#initialize(path, reason)`** has
pure mandatory arity and its own `"Failed to init bitmap: #{path}
(#{reason})"` string interpolation compiles clean (`STRING`/`STRCAT`,
`mrb_ensure_string_type`/`mrb_str_concat`), but the trailing
`super(...)` call itself hits `#error unhandled opcode SUPER` -- the
same, already-documented `SUPER` gap every other
`#initialize`-calling-`super` in this codebase hits (confirmed here via
this method's own real marker, not assumed identical merely because the
shape -- a nested exception class formatting a message into `super` --
looks familiar). One real wrinkle worth naming precisely:
`RGSS::Bitmap::LoadError`'s own registry owner string is
`RGSS::Bitmap::LoadError`, distinct from `RGSS::Bitmap` -- nested classes
get their own, separately-scoped owner name, not their enclosing class's
-- so with only `RGSS::Bitmap` in `ONLY_OWNERS` (this round's actual
`owners:` addition) this method is never even emitted, compiled or
`#error`-marked. The `SUPER` marker quoted above was confirmed by adding
`RGSS::Bitmap::LoadError` to `ONLY_OWNERS` in a separate, isolated
diagnostic run, not assumed from the shape alone; `RGSS::Bitmap::
LoadError` is not added to this round's real `owners:` list, since
nothing on it compiles either way.

**`self.failure_reason(f)` -- the real finding this round's own task
asked to verify rather than assume.** The task's own framing suggested
the established `SDEF` registry fix (this ADR's own `RGSS::Window`
follow-up, and the earlier fix documented around this file's
`RGSS::Timeout`/`SCLASS` writeup) "should make it visible to the registry
as a `.singleton`-owned method" -- true, but visibility to the registry
and eligibility to actually be compiled turned out to be two different
things, confirmed directly rather than assumed identical. `def
self.failure_reason(f)` is written as a bare `def self.x`, *not* nested
inside a `class << self ... end` block the way `attr_writer :extensions`/
`def extensions` above it are -- confirmed directly via a real `mrbc -v`
disassembly of the class body: `failure_reason` compiles to a single
fused `SDEF R1 :failure_reason I[3]` instruction, while `extensions`
compiles to an ordinary `TDEF R1 :extensions I[0]` nested inside a real
`SCLASS`-opened child body. bc2cpp.rb's own `SDEF` case registers its
`MethodDef` with `irep: nil` *unconditionally*, by explicit design --
its own comment states "there is no separate body to recurse into" for
this fused opcode, unlike `SCLASS`'s own body, which the registry walk
does genuinely recurse into (real `TDEF`s, real irep labels, exactly how
`self.extensions` gets a real one). `compile_all`'s own leaf worklist is
built from `@owner_of.keys`, and `@owner_of[d.irep] = d if d.irep` only
inserts a `MethodDef` that has a real `irep` -- so `self.failure_reason`
is *never inserted into that worklist at all*, regardless of
`ONLY_OWNERS`. Confirmed for real, not inferred from the source-level
argument alone: with `RGSS::Bitmap.singleton` added to `ONLY_OWNERS` in
an isolated diagnostic run, `failure_reason` appears in the real
whole-program registry dump (`MONO :failure_reason (1 def:
RGSS::Bitmap.singleton)`, exactly as the task's own framing expected) but
in *neither* the "skipped (unsupported)" summary *nor* the generated
`.cpp` file at all -- zero matches for `failure_reason` anywhere in the
real generated output, with or without `SKIP_UNSUPPORTED`. This is a
materially different (and stronger) kind of non-compilation than an
arity or opcode gap: those still produce a `#error`-marked stub that
`compile_method` actually attempted and rejected (visible in "skipped"
under `SKIP_UNSUPPORTED=1`, or as a real `#error` line in the `.cpp`
without it); `self.failure_reason` is never attempted by `compile_method`
at all, so its own body's real shape (`if`/early `return`/array `<<`/
ternary-in-array-push/`.join`/string interpolation -- every one of them
individually a supported shape elsewhere in this closed world) is never
even a factor. Confirmed this is not special to `failure_reason`'s own
body: this is a structural property of every bare `def self.x` in this
program (also observed for real, same `SDEF`+`irep: nil` shape, on
`RGSS::Bitmap.singleton#extensions=`'s sibling case below), not a
one-off quirk.

By contrast, **`self.extensions`** (inside the real `class << self ...
end` block, the same `SCLASS`-recursed body `attr_writer :extensions`
lives in) *is* a real, individually compilable leaf -- confirmed: it
appears in the real generated output as
`RGSS__Bitmap_singleton_extensions_impl` (a plain `@extensions ||
EXTENSIONS` reader, the same nil-guarded-`||`-default shape as
`RGSS::Window#blend_type`/`#stretch`) once `RGSS::Bitmap.singleton` is
added to `ONLY_OWNERS` in an isolated check. Neither `self.extensions`
nor `self.failure_reason` is added to this round's real `owners:` list,
though, since no `owners:` entry in this entire project has ever named a
`.singleton` pseudo-owner as an actual emission target -- every prior
follow-up's own full-sweep verification in this file confirms "no
pseudo-owner (`.singleton`-suffixed) symbol ever linked anywhere" -- and
this round keeps that precedent rather than being the first exception for
`RGSS::Bitmap` alone. `attr_writer :extensions`'s own `extensions=` is
`Module#attr_writer`'s native/C-installed setter (no bytecode `DEF` at
all, the same as every other `attr_writer`/`attr_accessor`-defined method
elsewhere in this codebase), invisible to bc2cpp regardless of owner
scoping either way.

**Embedding: none**, confirmed directly against the real diagnostic --
`RGSS::Bitmap` never appears in bc2cpp's own "classes needing
`MRB_SET_INSTANCE_TT`" listing. `drop_unsafe_embeddings`'s own
class-level gate requires a *compiling* `#initialize` with pure mandatory
arity before embedding anything on a class at all; `RGSS::Bitmap#initialize`
doesn't compile (non-mandatory arity, the same gate `RGSS::Window`'s own
`#initialize` already hits), so nothing on `RGSS::Bitmap` is ever even
proposed as an embedding candidate. `@font` is a `Font` object reference
(never `Fixnum`/`Symbol`) and would not be a `FixnumEmbed`/`SymbolEmbed`
candidate regardless of that gate either way -- confirmed, not merely
assumed from its type: `@font` never appears in the real "ivar embedding"
or "known-ivar-class hints" sections at all (it is only ever read/written
through `||=`/plain assignment, never Fixnum-literal-assigned, so
`IvarLayout` doesn't even propose it as a `CLASS_HINT` the way
`RGSS::Window#cursor_rect`'s own `@cursor_rect` does).

**Verified for real:** the real, opt-in `RPGMAKER_BC2CPP=1` pipeline was
run end to end in this worktree, hitting the same environment gap this
ADR's own `RGSS::Tilemap` follow-up (immediately above) already
documents -- `mruby-rgss`'s real LVGL final-link dependency has no build
step in this environment -- so this round used that same follow-up's own
established fallback: `git submodule update --init` for `3rd/mruby` and
its own real dependencies (`3rd/mruby-marshal`, `3rd/mruby-onig-regexp`,
`3rd/mruby-stringio`, `3rd/uni-algo`, `3rd/stb`, all uninitialized in this
fresh worktree, kept out of this round's own diff), then a real host
`mrbc` built from inside `3rd/mruby` itself (`HOST_CXX=c++`, `HOST_CC`
left as plain `cc` -- the same two fixes the `RGSS::Tilemap` follow-up's
own writeup already worked out and re-verified live here rather than
re-derived from scratch). With a real host `mrbc` (`mruby 4.0.0`) built
clean, `tools/bc2cpp/bc2cpp.rb` was run directly against it
(`ONLY_OWNERS`/`OTHER_OWNERS`/`NATIVE_SRCS` computed programmatically
from the real, already-edited `compiled_gems.rb` itself -- `BC2CPP_
COMPILED_GEMS.fetch('mruby-rgss-compiled')[:owners]` and the other two
gems' own `owners:` flattened for `OTHER_OWNERS` -- not hand-copied, so
this run reflects exactly what `mruby-rgss-compiled/mrbgem.rake`'s own
`file` rule would compute) over the whole `mruby-rpg2k`+`mruby-lcf`+
`mruby-rgss` closed world, `SKIP_UNSUPPORTED=1`. The real `==
compiled entry points ==`, "skipped (unsupported)", and "classes needing
`MRB_SET_INSTANCE_TT`" listings quoted above all came from that real run.
Grepped the real regenerated `rgss_compiled_gen.cpp` for the broken
empty-name `mrb_funcall(M, <reg>, "", ` shape: zero matches. Re-ran a
second time with `RGSS::Bitmap.singleton`/`RGSS::Bitmap::LoadError` added
to `ONLY_OWNERS` (an isolated diagnostic-only configuration, never the
real `owners:` this round ships) specifically to get the real markers for
`self.failure_reason`/`self.extensions`/`LoadError#initialize` quoted
above, rather than inferring them from the plain-`RGSS::Bitmap` run's own
silence about them.

`g++ -fsyntax-only -std=gnu++17 -Wall -Wextra -Winfinite-recursion`
against the real edited `register.cxx` plus that real generated file and
the real mruby headers (`3rd/mruby/include`, the real generated `mruby/
presym/id.h` from the plain host `mrbc` build above): **zero errors, zero
`-Winfinite-recursion` warnings** (only the same pre-existing, harmless
`-Wunused-but-set-variable` warnings every other compiled method here
already has, `RGSS::Bitmap#font`/`#font=` included). Compiled
`register.cxx` to a real object file and confirmed with `nm -C`:
`RGSS__Bitmap_font_impl`/`RGSS__Bitmap_font__impl` are present and
externally linked (`T`), their `mrb_get_args` wrappers
`RGSS__Bitmap_font`/`RGSS__Bitmap_font_` correctly stay local (`t`), and
`RGSS::Bitmap` appears in no embedding-struct symbol set at all,
confirming the embedding-none conclusion directly rather than assuming
it: no `RGSS__Bitmap_ivars` struct, no `MRB_SET_INSTANCE_TT` call, and
both compiled methods read/write `@font` through the ordinary dynamic
`iv_tbl`.
## Follow-up: RGSS::Font investigated, and NOT added -- the `.singleton` pseudo-owner mechanism confirmed sound but structurally incapable of ever emitting a real singleton-method entry point

A parallel round investigated `RGSS::Font` (`mruby-rgss/mrblib/lib.rb`,
line 768) as `mruby-rgss-compiled`'s fifth owner. Read in full from the
real source rather than assumed from a summary:

```ruby
class Font
  @default_name = "Arial"
  @default_size = 22
  @default_bold = false
  @default_italic = false
  @default_shadow = false
  @default_outline = true
  @default_color = Color.new(255, 255, 255, 255)
  @default_out_color = Color.new(0, 0, 0, 128)
  # Font file used when the project ships none. See #default_path below.
  @default_path = nil

  class << self
    attr_accessor :default_name, :default_size, :default_bold,
                  :default_italic, :default_shadow, :default_outline,
                  :default_color, :default_out_color

    # Path to a font file draw_text falls back to when the project itself
    # ships none ... (attr_accessor :default_path)
    attr_accessor :default_path

    def exist?(name)
      true
    end
  end

  attr_accessor :name, :size, :bold, :italic, :outline, :shadow,
                :color, :out_color

  def initialize(name = Font.default_name, size = Font.default_size)
    @name = name
    @size = size
    @bold = Font.default_bold
    @italic = Font.default_italic
    @shadow = Font.default_shadow
    @outline = Font.default_outline
    c = Font.default_color
    @color = Color.new(c.red, c.green, c.blue, c.alpha)
    oc = Font.default_out_color
    @out_color = Color.new(oc.red, oc.green, oc.blue, oc.alpha)
  end
end
```

**Conclusion up front: `RGSS::Font` was NOT added to `owners:` in
`tools/bc2cpp/compiled_gems.rb`.** Every real, bytecode-defined method on
this class -- `#initialize` and the `class << self`-opened `.exist?` --
was confirmed, against the real diagnostic rather than assumed, to be
either out of this prototype's supported subset or structurally
incapable of ever being *emitted* as a compiled entry point under the
current `ONLY_OWNERS` mechanism, however this gem's owners list is
written. `attr_accessor :name, :size, :bold, :italic, :outline, :shadow,
:color, :out_color` (8 instance-level names) and the `class << self`'s
own `attr_accessor :default_name, ..., :default_path` (8 more,
class-level) stay native/uncompiled, as always -- neither is a real
bytecode-defined method. Adding this class as an owner would add zero
real compiled coverage while adding a permanent maintenance liability
(an owners-list entry with nothing behind it), so this round leaves
`owners: %w[RGSS::Sprite RGSS::Plane RGSS::Tilemap RGSS::Window]`
unchanged and documents the investigation here instead, per this ADR's
own explicit guidance for exactly this outcome.

**`#initialize(name = Font.default_name, size = Font.default_size)`
does not compile**, confirmed directly against the real `#error` marker
(`SKIP_UNSUPPORTED=0`), not merely inferred from its two optional
arguments:
```
#error RGSS::Font#initialize has non-mandatory arguments (optional/rest/keyword/block) -- not in this prototype's supported subset
```
The same `pure_mandatory_arity?` gap every other optional-argument
`#initialize` in this codebase already hits -- fires unconditionally on
the signature, before any of the body's own SEND instructions (the four
`Font.default_*` class-method calls, the two `Color.new` constructor
calls) are ever inspected. Both default expressions being real calls
into another class's own singleton accessor (`Font.default_name`,
`Font.default_size`), rather than literal defaults, makes no difference
here -- `pure_mandatory_arity?` only ever inspects the `ENTER` opcode's
own mandatory/optional counts, never the default-value expressions
themselves, so a non-trivial default drops the method exactly the same
way a trivial literal default would.

**`.exist?(name)`, the `class << self`-opened singleton method, IS
correctly visible to the whole-program registry** -- the SCLASS/
`"X.singleton"` pseudo-owner mechanism this ADR's own `Game::Vehicle`
follow-up (its sixth severe bug fix, several rounds up) added is
confirmed live and working here, not just in theory. The real registry
dump shows:
```
MONO  :exist?  (1 def: RGSS::Font.singleton)
```
-- `RGSS::Font.exist?` really is the *sole* definition of `:exist?`
anywhere in the whole closed world (`mruby-rpg2k`+`mruby-lcf`+
`mruby-rgss`'s own mrblib, plus every native `mrb_define_method`/
`mrb_define_class_method` site scraped from `NATIVE_SRCS`) -- confirmed
by grepping the full registry dump for every `:exist?` line, not
assumed unique: exactly one line, `MONO`, no unrelated `#exist?`/
`.exist?` definition anywhere else in the program to confuse it with.
The class-body-level `class << self` `attr_accessor`s register the same
way: `default_name`/`default_size`/`default_bold`/`default_italic`/
`default_shadow`/`default_outline`/`default_color`/`default_out_color`/
`default_path` and their `=` writers all show up as `MONO (1 def:
RGSS::Font.singleton)` in the real dump too, exactly the synthetic,
irep-less `MethodDef` shape this ADR's own `attr_accessor`-registration
mechanism already gives every other native/class-level accessor.

**But `.exist?` can never become a real emitted compiled entry point --
confirmed empirically, not just from the `"X.singleton"` pseudo-owner
design comment.** `CodeGen#compile_all`'s own `only_owners` filter
(`tools/bc2cpp/bc2cpp.rb`) is a plain string-membership check:
```ruby
leaves = leaves.select { |l| only_owners.include?(@owner_of.fetch(l).owner) } if only_owners
```
Every gem's `mrbgem.rake` (`target_owners = this_gem[:owners]`) passes
`ONLY_OWNERS` through *exactly* as written in `compiled_gems.rb`'s
`owners:` array -- a list of real Ruby constant paths, never
`.singleton`-suffixed, by convention across all three compiled gems in
this codebase (confirmed by grepping every `owners:` line in
`compiled_gems.rb` and every `mrb_define_class_method`/
`mrb_define_singleton_method` call anywhere in `mruby-lcf-compiled/`,
`mruby-rpg2k-compiled/`, `mruby-rgss-compiled/`'s own `src/register.cxx`
files -- zero matches for either shape anywhere: no compiled gem has ever
had, or emitted, a real class-method registration). So `RGSS::Font.
exist?`'s own registry owner (`"RGSS::Font.singleton"`) can never equal
a plain `"RGSS::Font"` entry in `owners:`, no matter how that array is
written -- this is not a bug to fix, it is exactly the isolation the
pseudo-owner suffix was designed to guarantee (see the `Game::Vehicle`
follow-up's own comment: "a distinct `"X.singleton"` pseudo-owner ...
which can never collide with or be selected by `ONLY_OWNERS`"). The
mechanism exists purely to keep the whole-program MONO/POLY registry
*sound* for other call sites elsewhere in the program that might call
`.exist?` on some *other* receiver -- never to make the singleton method
itself compilable. Every prior instance of this same shape in this
codebase (`Game::MoveRoute.from_page`/`.same_route?`, `Game::ChipSet.
lower_index`, `Game::EventGraphic.numpad_direction`, `RPG2k::Scene::Map.
tone_channel`) has the identical fate: correctly registered, MONO or
POLY as appropriate, never emitted, regardless of whether the
*instance*-level class happens to be a compiled owner.

Verified this holds for real, not just from reading the filter code:
ran `tools/bc2cpp/bc2cpp.rb` directly against a real host `mrbc` (built
in this worktree specifically for this check -- see Verification below)
with `ONLY_OWNERS=RGSS::Sprite,RGSS::Plane,RGSS::Tilemap,RGSS::Window,
RGSS::Font` (i.e. *with* `RGSS::Font` added) over the whole closed
world. The real `== compiled entry points ==` listing contains **36**
lines total -- 17 `RGSS::Sprite`, 6 `RGSS::Plane`, 1 `RGSS::Tilemap`, 12
`RGSS::Window`, **zero** `RGSS::Font`. A second run with `RGSS::Font`
left out of `ONLY_OWNERS` entirely produces the byte-for-byte identical
36-line listing (`diff` confirms zero lines differ) -- decisive
confirmation that adding `RGSS::Font` to this gem's `owners:` would
contribute exactly zero new compiled coverage, not merely a plausible
inference from the filter's source. The `== skipped (unsupported, left
on the interpreter) ==` listing shows `RGSS::Font#initialize` (alongside
the already-shipped `RGSS::Window#initialize`) -- `.exist?` does not
even appear there, since it was never a candidate leaf for this
`ONLY_OWNERS` run in the first place (its owner string never matched).

**Class-body-level ivar assignments are not per-instance ivars, and are
correctly irrelevant to embedding either way.** The nine assignments at
the top of the class body (`@default_name = "Arial"`, `@default_size =
22`, ..., `@default_path = nil`) execute exactly once, at class-
definition time, directly on the `Font` *class object* itself (`self`
inside a bare class body is the class being defined) -- they are class
ivars on `Font`, read back by the `class << self` `attr_accessor`s
above, and have nothing to do with the *instance*-level `@name`/`@size`/
`@bold`/`@italic`/`@outline`/`@shadow`/`@color`/`@out_color` ivars
`#initialize` sets on each `Font.new` object. Conflating the two would
be a real category error: `IvarLayout`'s own embedding analysis only
ever looks at ivars set inside compiled *instance* methods, and these
nine assignments live inside a `CLASS`-opened body's own top-level EXEC,
never inside any `TDEF`-registered method at all, so they were never
even candidates for `IvarLayout`/embedding analysis to consider.

**`#initialize` not compiling means the *instance*-level ivars stay
unembedded, but they are still set correctly at runtime, by the ordinary
interpreter.** This distinction matters and is stated precisely here:
"not compiled" and "not set" are different things. This whole compiler
is a strict opt-in optimization (`RPGMAKER_BC2CPP=1`) with the ordinary
mruby bytecode interpreter as the unconditional fallback for anything
unsupported -- `#initialize`'s own `#error ... has non-mandatory
arguments` marker only ever means bc2cpp.rb declines to *emit a
compiled C++ replacement* for this one method; the original bytecode
`irep` is untouched and still runs on the normal interpreter path
exactly as mrbc compiled it, so every `Font.new` still gets real,
correct `@name`/`@size`/`@bold`/`@italic`/`@shadow`/`@outline`/`@color`/
`@out_color` values set on it at runtime, the same as before this class
was ever investigated. Nothing about "doesn't compile" implies "doesn't
run" or "runs wrong" anywhere in this prototype -- under-compiling is
always safe, by design. Confirmed directly against the real embedding
diagnostic besides: `RGSS::Font` does not appear in bc2cpp's own
"classes needing `MRB_SET_INSTANCE_TT`" listing at all (that listing,
with `RGSS::Font` included in `ONLY_OWNERS`, was `Game::Transition`,
`Game::Screen`, `Game::Interpreter`, `RPG2k::Scene::VehicleWorld`,
`RPG2k::Scene::Map::LRUBitmapCache` -- five classes, none of them
`RGSS::Font`, identical to the baseline run without `RGSS::Font`) --
`drop_unsafe_embeddings`'s own class-level gate requires a *compiling*
`#initialize` with pure mandatory arity before embedding anything on a
class at all, and `#initialize` here fails that gate outright, so none
of this class's own ivars (including the two Color-typed ones,
`@color`/`@out_color`, which would need object-typed embedding support
this prototype doesn't have anyway) was ever even proposed as an
embedding candidate.

This round leaves `tools/bc2cpp/compiled_gems.rb`'s `mruby-rgss-compiled`
owners list and `mruby-rgss-compiled/src/register.cxx` both completely
unchanged -- there is nothing to register. No new opcode work, no new
live bc2cpp.rb bug found or fixed.

**Verified for real, environment gap noted rather than worked around,
same shape this ADR's own `RGSS::Tilemap`/`LCF::EventCommand`/
`Game::Rng` follow-ups already established**: a fresh clone of this
worktree needed the same six mruby submodules (`3rd/mruby`, `3rd/mruby-
marshal`, `3rd/mruby-onig-regexp`, `3rd/mruby-stringio`, `3rd/uni-algo`,
`3rd/stb`) initialized (`git submodule update --init`) and the same nine
`patches/*.patch` files applied by hand via `scripts/
apply_mruby_patch.bash` (a raw `rake -f 3rd/mruby/Rakefile` invocation
runs no CMake configure step, so none of this happens automatically).
Built the real host `mrbc` by running `rake` from *inside* `3rd/mruby`
itself with `HOST_CXX=c++` (the same `Dir.pwd == MRUBY_ROOT` /
C++-linker-for-C++-exception-runtime reasoning this ADR's own
`RGSS::Tilemap` follow-up already documents in detail) -- built clean,
`mruby 4.0.0`. Ran `tools/bc2cpp/bc2cpp.rb` directly against that real
host `mrbc` (`ONLY_OWNERS`/`NATIVE_SRCS`/`SKIP_UNSUPPORTED` computed
exactly the way `mruby-rgss-compiled/mrbgem.rake` does) over the whole
`mruby-rpg2k`+`mruby-lcf`+`mruby-rgss` closed world, both with and
without `RGSS::Font` in `ONLY_OWNERS` -- every quoted listing and diff
above came from those two real runs, not simulated. Grepped both real
regenerated files for the broken empty-name `mrb_funcall(M, <reg>, "",
` shape: zero matches in either. Did not reach the real `mruby-rgss`/
LVGL final-link gap this ADR's prior follow-ups already document, since
there was no edited `register.cxx` needing the `g++ -fsyntax-only`
fallback this round -- nothing was generated that needed compiling at
all.

## Follow-up: Game::Actor/Game::Party (battle_support.rb) coverage

A dedicated round was asked to add coverage for `mruby-rpg2k/mrblib/game/
battle_support.rb`'s own **separate** reopening of both `Game::Actor` and
`Game::Party` (distinct from `mruby-rpg2k/mrblib/game.rb`'s own ~2,100-
and ~2,300-line main class bodies for each -- see the `Game::Transition,
Game::Actor` and `Game::Party, RPG2k::Scene::MapViewer` follow-ups several
rounds up for those). **Conclusion up front: zero registration changes**
-- both classes were already fully, correctly covered by an earlier
round's own work on this exact reopening, confirmed for real against the
actual diagnostic rather than assumed from `register.cxx`'s own claims.
What this round found and fixed were two real, confirmed documentation
gaps in `register.cxx`'s and `tools/bc2cpp/compiled_gems.rb`'s own
comments, not a missing opcode or a missing registration.

**Environment, built fresh in this round's own worktree** (same shape
this ADR's own `RGSS::Tilemap`/`Game::Rng`/`RGSS::Font` follow-ups already
document): `git submodule update --init 3rd/mruby 3rd/mruby-marshal
3rd/mruby-onig-regexp 3rd/mruby-stringio 3rd/uni-algo 3rd/stb`, the nine
`patches/*.patch` files applied by hand via `scripts/
apply_mruby_patch.bash` (a raw `rake -f 3rd/mruby/Rakefile` run performs
no CMake configure step, so none of this happens automatically), then a
real host `mrbc` built by running `rake` from *inside* `3rd/mruby` itself
with `HOST_CXX=c++` (`mruby 4.0.0`, built clean). `tools/bc2cpp/bc2cpp.rb`
was run directly against that real `mrbc`, with `ONLY_OWNERS`/
`OTHER_OWNERS`/`OTHER_DECLS_HEADER`/`NATIVE_SRCS`/`SKIP_UNSUPPORTED`
computed exactly the way `mruby-rpg2k-compiled/mrbgem.rake` (and, for the
cross-gem-devirtualization angle below, `mruby-lcf-compiled/mrbgem.rake`
and `mruby-rgss-compiled/mrbgem.rake` too) compute them, over the whole
`mruby-rpg2k`+`mruby-lcf`+`mruby-rgss` closed world -- both with
`SKIP_UNSUPPORTED=1` (the real build's own setting, to read the `==
compiled entry points ==`/`== skipped ==` listings) and with
`SKIP_UNSUPPORTED=0` (to see each skipped method's own real `#error`
marker directly, rather than only its name).

**`battle_support.rb`'s own `class Actor` reopening (lines 14-198)
defines 13 real bytecode-defined methods, not the 9 `register.cxx`'s own
comment said.** Reading the real source directly (not summarized) found
`#alive?`, `#states=`, `#prevents_critical?`, `#state_resist_mul`,
`#attack_animation_id`, `#ignores_evasion?`, `#attack_all?`,
`#preemptive?`, `#weapon_sp_cost`, `#physical_evasion_up?`, `#atb_gauge=`,
`#clear_battle_combo`, `#skill_command_name` -- 13 methods. 9 of them
(every one but `#states=`, `#prevents_critical?`, `#state_resist_mul`,
`#physical_evasion_up?`) were already registered in `register.cxx`,
confirmed exactly matching the real `== compiled entry points ==`
listing's own `Game::Actor#...` lines (74 total, matching `register.cxx`'s
own `grep -c 'M, actor,'` count exactly, both before and after this
round's changes). But the comment introducing that block of 9
registrations said "The 9 methods mruby-rpg2k/mrblib/game/
battle_support.rb's own `class Actor` reopening adds" -- true only if read
as "the 9 that compile", never stated, and never naming the other 4 or
explaining why they're absent. Confirmed directly against each of those
4's own real `#error` marker (`SKIP_UNSUPPORTED=0`), not merely guessed
from the Ruby source shape: every one ends in a genuine Ruby block, the
same already-established `#error unhandled opcode BLOCK`/`SENDB`
out-of-scope shape this whole file already documents dozens of times over
--

```
mrb_value Game__Actor_states__impl(mrb_state* M, mrb_value self, mrb_value ids) {
  ...
  #error unhandled opcode BLOCK -- not in this prototype's supported subset
  #error unhandled opcode SENDB -- not in this prototype's supported subset
  // POLY :uniq -- real dynamic dispatch, receiver's runtime class decides
  r3 = mrb_funcall(M, r3, "uniq", 0);
  ...
```

-- `#states=(ids)`'s own `(ids || []).reject { |s| s.nil? || s == 0 }.uniq`
(the `.reject { |s| ... }` call is the block; `.uniq` itself is an
ordinary POLY send, unaffected); `#prevents_critical?`'s and
`#physical_evasion_up?`'s own `@equipment.any? do |iid| ... end` (same
`Array#any?` call site, different block bodies); `#state_resist_mul`'s own
`@equipment.each do |iid| ... end`. `#states=` is POLY in the
whole-program registry (2 defs: `Game::Actor`, `Game::Battle::Combatant`);
`#prevents_critical?`/`#state_resist_mul`/`#physical_evasion_up?` are each
MONO (1 def: `Game::Actor`) -- confirmed directly, though irrelevant here
either way, since none of the four ever reaches codegen far enough to
need a dispatch-mode decision at all. `register.cxx` now names and
explains all 4 in the same place the 9 registrations live (see that
file's own comment); no method was ever mis-registered and nothing was
ever unsafe -- this was a documentation-completeness gap only, the same
class of finding this ADR's own "second adversarial full-sweep" follow-up
several rounds up already established a name for.

**`battle_support.rb`'s own `class Party` reopening (lines 199-779)
was independently re-verified the same way and found fully, correctly
documented in method membership** -- 24 real bytecode-defined methods
(`#gauge_battle_layout?`, `#automatic_battle_placement?`,
`#skill_helps_troop?`, `#battle_skills`, `#battle_skill?`,
`#battle_occasion?`, `#battle_skill_target`, `#skill_absorbs?`,
`#skill_hit`, `#skill_hit_weapon_fallback`, `#skill_to_hit`,
`#do_nothing_restricted?`, `#hit_modifier`, `#state_hit_ratio`,
`#skill_variance`, `#skill_attributes`, `#skill_attr_shift`,
`#skill_stat_mod_keys`, `#battle_skill_command`, `#skill_invoking_item?`,
`#battle_usable?`, `#battle_items`, `#battle_item_command`,
`#item_all_allies?`), 16 registered and 8 correctly left interpreted,
matching `register.cxx`'s own "16 the battle_support.rb reopening adds"
claim and its own "43 real methods stay interpreted" total for the whole
class (`Game::Party`'s main `game.rb` body plus this reopening) exactly --
confirmed against the real `== compiled entry points ==` listing (85
`Game::Party#...` lines, matching `register.cxx`'s own `grep -c 'M,
party,'` count) and the real `== skipped ==` listing.

**But one real, confirmed misattribution was found and fixed in that same
Party comment**: it listed "`#hit_modifier`/`#stat_mode`/
`#do_nothing_restricted?`/..." as methods "the battle_support.rb
reopening's own" -- `#stat_mode` is not part of that reopening at all. Its
real definition (`def stat_mode(b, stat_flag)`) is in `mruby-rpg2k/
mrblib/game.rb` line 5716, inside `class Party`'s own main ~2,300-line
body (`class Party` opens at game.rb line 3677, well before 5716) -- a
second, separate `Game::Party#stat_mode` from the one `Game::Battle`
defines (`POLY :stat_mode (2 defs: Game::Battle, Game::Party)` in the real
whole-program registry), unrelated to the `battle_support.rb` reopening
entirely. It does genuinely stay interpreted for the identical reason
(its own `(b.states || []).each { |sid| ... }` hits the same BLOCK/SENDB
gap, confirmed directly against its own real generated body), so the
total "43 real methods stay interpreted" count and the "25 use a real
Ruby block" sub-count were never wrong -- only which of two lists
`#stat_mode`'s own name belonged under. `#battle_skill_command` (a real
`battle_support.rb` reopening method, blocked by its own `free: false`
keyword argument -- confirmed against its own real `#error
Game::Party#battle_skill_command has non-mandatory arguments
(optional/rest/keyword/block)` marker, and never even reaching codegen
far enough to get a real function body, unlike the BLOCK/SENDB-blocked
methods above) was already correctly named elsewhere in that same
comment, in the non-mandatory-arity group its own real error marker
belongs to -- not a second gap despite superficially looking related to
the `#stat_mode` fix. `register.cxx`'s own comment is corrected in place;
`tools/bc2cpp/compiled_gems.rb` gets a new paragraph documenting this
round's full re-check (both fixes, plus the real verification numbers)
rather than rewriting its own pre-existing historical "76 of its own real
bytecode-defined methods" snapshot for `Game::Actor` -- consistent with
how that file already treats every earlier round's own count as a
timestamped snapshot rather than a live total to keep editing in place
(the later `#knock_out!`/`#restore_class` `compile_send`-fix paragraph a
few rounds up follows the identical convention).

**Verified for real, not just re-derived from reading the two files'
comments.** Beyond the `#error`-marker checks above: the real `==
compiled entry points ==` listing's `Game::Actor#...`/`Game::Party#...`
line counts (74/85) match `register.cxx`'s own `grep -c 'M, actor,'`/
`grep -c 'M, party,'` counts exactly, both before and after this round's
edits (which touch only comments, zero `mrb_define_method`/
`mrb_define_private_method` call sites added, removed, or reordered).
The real `== classes needing MRB_SET_INSTANCE_TT(..., MRB_TT_DATA) ==`
listing is unchanged by this round (`Game::Transition`, `Game::Screen`,
`Game::Interpreter`, `RPG2k::Scene::VehicleWorld`,
`RPG2k::Scene::Map::LRUBitmapCache` -- neither `Game::Actor` nor
`Game::Party`, consistent with both classes' own `#initialize` staying
interpreted, documented several rounds up). Grepped every regenerated
file (`mruby-lcf-compiled`, `mruby-rpg2k-compiled`, `mruby-rgss-compiled`,
generated together with real cross-gem `OTHER_DECLS_HEADER` wiring so
`RGSS::Bitmap`-devirtualizing scene methods resolve) for the broken
empty-name `mrb_funcall(M, <reg>, "", ` shape: zero matches in all three.
Compiled the real, edited `mruby-rpg2k-compiled/src/register.cxx` itself
with `g++ -std=c++17 -c` (not just `-fsyntax-only`) against the real host
`mrbc`-generated `mrbconf.h`/presym headers and all three gems' real
generated `.cpp`/`_decls.h` files, mirroring the real build's own
`#include` structure exactly -- **zero errors**, a real `.o` file
produced. `nm -C` on that object file confirms every expected symbol
exists and nothing extra was registered: exactly 74 non-static
`Game__Actor_..._impl` symbols and 74 matching `static` wrapper symbols
(`Game__Actor_alive_`, `Game__Actor_attack_animation_id`,
`Game__Actor_ignores_evasion_`, `Game__Actor_attack_all_`,
`Game__Actor_preemptive_`, `Game__Actor_weapon_sp_cost`,
`Game__Actor_atb_gauge_`, `Game__Actor_clear_battle_combo`,
`Game__Actor_skill_command_name`, ... among them, the 9 confirmed
present), zero `Game__Actor_states_`/`Game__Actor_prevents_critical_`/
`Game__Actor_state_resist_mul`/`Game__Actor_physical_evasion_up_` wrapper
symbols (confirmed absent, matching them staying unregistered); and
exactly 85 non-static `Game__Party_..._impl` symbols with 85 matching
wrapper symbols. Did not attempt the full real `build_config.rb` + `rake`
+ CMake/SDL/LVGL end-to-end build this ADR's own original `LCF::File` and
`Game::Picture` follow-ups ran (a materially heavier lift than this
round's own comment-only diff justifies) -- the `g++ -c` object-file
compile plus `nm -C` symbol check above is the real, load-bearing
verification for a change that touches zero `mrb_define_method`/
`mrb_define_private_method` call sites, matching the depth this ADR's own
"RGSS::Font investigated, and NOT added" follow-up already used for a
comparable investigation-only round.

Both `mruby-rpg2k-compiled/src/register.cxx` and
`tools/bc2cpp/compiled_gems.rb` were changed (`clang-format -i` then
`clang-format --dry-run --Werror` run clean on the `.cxx` file
afterward); no other file needed a change. Zero methods gained or lost
registration; the only externally-visible effect of this round is that
`register.cxx`'s and `compiled_gems.rb`'s own comments now correctly and
completely account for every real method `battle_support.rb`'s reopening
of `Game::Actor`/`Game::Party` defines.


## Follow-up: adversarial bug-hunt sweep (round 27)

A dedicated adversarial bug-hunt round, not a coverage round: read
`docs/adr/0139-bc2cpp-lcf-file-aot-compile.md` (this file) in full,
`tools/bc2cpp/bc2cpp.rb`, `tools/bc2cpp/compiled_gems.rb`, and all three
`register.cxx` files end to end, then verified the real, current
60-owner, three-gem closed world against the actual tool output rather
than trusting any prior round's own numbers. Focus: new bugs only, not
re-litigating anything this file's own 30+ prior follow-ups already
found and fixed.

**Environment.** This worktree's own `3rd/mruby` (and every other `3rd/*`
submodule) is uninitialized (a fresh-worktree gap this file already
documents repeatedly) -- used the same, now-established workaround: the
main checkout's own separate, already-built `3rd/mruby` tree (for its
real headers and a real, pre-built host `mrbc 4.0.0`) alongside this
worktree's own real `mruby-rpg2k`/`mruby-lcf`/`mruby-rgss` sources (the
actual code under review). Replayed all three `mrbgem.rake` files'
own exact `bc2cpp.rb` invocations by hand (`MRBC`/`OUT_SYMBOL`/
`ONLY_OWNERS`/`OTHER_OWNERS`/`OTHER_DECLS_HEADER`/`NATIVE_SRCS`/
`SKIP_UNSUPPORTED` computed programmatically from the real, current
`compiled_gems.rb` -- `Dir[]`-based `closed_world_mrblib_srcs`/
`core_native_srcs`, never hand-copied), plus one whole-program,
unrestricted (`ONLY_OWNERS` unset) run for the full registry/embedding
dump. 60 real owners across the three gems today (11 `mruby-lcf-
compiled`, 44 `mruby-rpg2k-compiled`, 5 `mruby-rgss-compiled`); 545
native names from `NATIVE_SRCS`, 39 flipped MONO-to-POLY -- both numbers
matching this file's own most recently recorded figures exactly, no
drift.

**Checked, confirmed clean (no new bug found):**

- `grep -c 'mrb_funcall(M, [a-z0-9]*, "", '` (the project's own empty-
  method-name bug detector) against all three real, fully-regenerated
  `*_gen.cpp` files, and against the unrestricted whole-program dump:
  **zero** everywhere, as required.
- `GETMCNST`'s own name-extraction regex (`$`-anchored, the same shape
  already fixed once for `GETCONST` and re-checked once before against a
  smaller owner set) -- re-grepped all real `GETMCNST` instructions in
  the *current*, larger closed-world disassembly for a trailing
  `; R<n>:name` local-variable comment: still **zero** real occurrences,
  confirmed fresh rather than trusted from the earlier, smaller-owner-set
  check.
- **Exhaustive, not spot-checked, registration cross-diff** for all
  three `register.cxx` files against the real, freshly regenerated
  `== compiled entry points ==` listings: wrote a small script comparing
  every `(owner, method_name)` pair the diagnostic reports against every
  `mrb_define_(private_)method` call actually present in each
  `register.cxx` (resolving each call's own `RClass*` variable back to
  its real owner path through the file's own `mrb_module_get`/
  `mrb_class_get`/`mrb_module_get_under`/`mrb_class_get_under` chain).
  **893 total registered methods across all three gems (33 + 822 + 38),
  zero mismatches in either direction** -- every method the diagnostic
  says should be registered is, and nothing extra is registered. Also
  cross-checked every entry's own **arity** (`MRB_ARGS_REQ(n)`/
  `MRB_ARGS_NONE()` against the diagnostic's own reported arity) and
  **visibility** (`mrb_define_private_method` used for, and only for,
  every entry the diagnostic flags `[private -- ...]`, including all
  355 private entries in `mruby-rpg2k-compiled` alone) the same
  exhaustive way: zero mismatches on either axis, across all three
  files. This is a materially more thorough check than any single prior
  round ran (each prior round's own verification checked its own new
  classes this way, plus a summary entry-point *count* for every
  already-shipped class -- this round cross-checked every field of every
  entry across the whole, current 60-owner program in one pass).
- The three currently-embedding classes' real generated `struct
  ..._ivars` field lists (`Game::Transition`: `width`/`height`;
  `Game::Screen`: `flash_b`/`flash_g`/`flash_r`/`flash_power`/
  `flash_strength`/`flash_total`/`pan_tx`/`pan_ty`/`fade`/`fade_target`;
  `RPG2k::Scene::VehicleWorld`: `type`) against the real, current
  unrestricted diagnostic and against the real `MRB_SET_INSTANCE_TT`
  calls actually present in `register.cxx` (`screen`, `transition`,
  `vehicle_world` -- exactly three, matching exactly the three
  compiled-owner entries in the diagnostic's own five-item "classes
  needing `MRB_SET_INSTANCE_TT`" list, the other two -- `Game::
  Interpreter`, `RPG2k::Scene::Map::LRUBitmapCache` -- real candidates
  that are simply not owners of any gem yet). No drift found -- this
  file's own two most recent stale-comment findings (`Game::Screen`/
  `Game::Transition` overstating their own embedded field counts) are
  still the last real instance of this, not a new one.
- Re-checked the already-known-and-deliberately-left-open `Enumerable`
  bytecode-stdlib registry blind spot (`select`/`reduce`/`sort_by`/
  `min_by`/`max_by`/`group_by`/`partition`/`none?`/`one?`/`each_slice`/
  `each_cons`/`tally`/`take_while`/`drop_while`/`each_with_object`/
  `minmax`/`flat_map`/`map`) against the *current*, larger 60-owner
  closed world specifically (this file's own last check of this angle
  was against a smaller owner set, several rounds up) -- grepped every
  `MONO`/`TYPED` devirtualization comment in the real unrestricted
  generated output for any of these names: **zero matches**, still not
  live with `RGSS::Bitmap`/`RGSS::Window`/`RGSS::Tilemap`/`Game::Vehicle`/
  `Game::Enemy`/`RPG2k3::Scene::Battle`/`Game::MessageConfig` and every
  other recently-added owner now in the program.
- Re-verified `core_native_srcs`' own hardcoded core-mrbgem list
  (`array-ext`/`hash-ext`/`enum-ext`/`io`/`dir`/`numeric-ext`/
  `range-ext`/`fiber`/`exit`/`sprintf`/`kernel-ext`/`random`/`math`/
  `time`/`bigint`) against `build_config.rb`'s own real `conf.gem core:
  'mruby-xxx'` calls directly (this file's own comment on that helper
  flags it as manually-synced, with no automatic enforcement the way
  `BC2CPP_COMPILED_GEMS`/`closed_world_mrblib_srcs` now have) -- exact
  match, 15 for 15 (`mruby-bin-mrbc`, the `mrbc` build tool itself, is
  the one core gem in `build_config.rb` not in this list, correctly
  irrelevant here: it registers no runtime methods on any interpreter
  class). Separately noted `mruby-dir` is conditionally excluded for the
  `wio` target (`conf.gem core: 'mruby-dir' unless conf.name == 'wio'`)
  while `core_native_srcs` always includes it -- an intentional,
  harmless over-approximation (NATIVE_SRCS only ever *adds* POLY flips;
  scanning a gem that happens to be absent from one particular build
  target can only make the registry more conservative, never unsound),
  not a bug.
- All three real, freshly regenerated `register.cxx` files compile
  clean with `g++ -std=gnu++17 -Wall -Wextra -Winfinite-recursion
  -fsyntax-only`, with `OTHER_DECLS_HEADER` properly wired so a
  cross-gem devirtualized call (none currently exist in the live output,
  confirmed by the same registration cross-diff above) would still
  resolve if one ever did: **zero errors, zero `-Winfinite-recursion`
  warnings** in all three, only the same pre-existing, unrelated
  `-Wunused-but-set-variable` noise this file already documents in many
  earlier rounds. Compiled all three to real object files (`g++ -c`) and
  confirmed with `nm -C`: 79 / 1662 / 87 real `T`/`t` symbols
  respectively, consistent with roughly double each gem's own registered
  entry-point count (an `_impl` plus an entry wrapper per method, plus
  embedded-struct helpers for the three embedding classes).
- Considered, and ruled out as an already-accepted (if inconsistently
  documented) tradeoff rather than a new bug: `ADD`/`SUB`/`MUL`'s own
  fixnum-fixnum fastpath codegen does a raw C `+`/`-`/`*` on `mrb_int`
  with no overflow check, while the real interpreter's own `OP_MATH`
  macro (`3rd/mruby/src/vm.c`) checks for overflow and promotes to a
  real bignum via `mrb_bint_*_ii` (this project enables `mruby-bigint`)
  -- a genuine silent-divergence shape for an input large enough to
  overflow `mrb_int`. Not new: `ADDI`'s own codegen comment already
  names and explicitly accepts this exact tradeoff ("C's own wraparound
  on overflow is no worse a divergence here than ADDI's own plain C +
  already is... not worth duplicating mruby's own bignum-overflow path
  for this prototype's scope"), just never restated on `ADD`/`SUB`/`MUL`/
  `ADDILV`/`SUBILV` individually even though all five opcodes share the
  identical fixnum-fastpath shape and the identical real `OP_MATH`/
  `OP_MATHI`/`OP_MATHILV` overflow-promotion semantics underneath
  (confirmed directly against `3rd/mruby/src/vm.c`, not assumed). Not
  practically reachable in this codebase's own real game-state values
  (levels/HP/gold/coordinates, all far below `mrb_int`'s own range) --
  same severity bar this project's own established `DIV`-rounding
  writeup already sets for "a real, accepted simplification, not
  chased further."

**Found and fixed: a real, previously-undocumented registry gap
(`module_function`), confirmed not currently live.** `build_registry`'s
bytecode walk recognized `private`/`protected`/`public` and
`attr_reader`/`attr_writer`/`attr_accessor` sends as ways a class
installs a method invisibly to a plain `TDEF`/`DEF` walk, but never
`module_function :a, :b, ...` -- a fourth, distinct instance of the same
"bare `SEND`, no dedicated opcode" shape, never previously discussed
anywhere in this file. Real, live use in the current closed world,
found by grepping the whole `mruby-rpg2k`/`mruby-lcf`/`mruby-rgss`
mrblib tree for the keyword directly rather than assumed absent:
`mruby-lcf/mrblib/lcf.rb`'s own `module_function :read_ber, :write_ber,
:to_rb, :read_section, :parse_event_commands, :encode_event_commands,
:parse_move_commands, :encode_move_commands, :unpack_int32,
:unpack_double, :pack_int32, :pack_int16, :pack_double, :encode,
:binstr, :elements_of` (16 names) and `module_function :var_max,
:var_min, :level_max, :pc_hp_max, :npc_hp_max, :exp_default` (6 names)
-- both the retroactive (`n >= 1`) form only; the bare mode-switch form
has zero real occurrences anywhere in the closed world.

Read `3rd/mruby/src/class.c`'s own `mrb_mod_module_function` directly
before writing any fix, rather than assumed from CRuby's own (different)
behavior: unlike CRuby, mruby's own implementation does **not** make the
original instance method private -- the line that would
(`mrb_mod_dummy_visibility`) is commented-out dead code right above the
real loop. It only looks up each already-defined instance method and
installs a copy of it, marked public, onto the module's own singleton
class (`prepare_singleton_class` + `mrb_define_method_raw(mrb,
rclass->c, ...)`). So `LCF.write_ber`/`LCF.binstr`/... (called from
`LCF::File#to_lcf` and from several lazy schema-default lambdas) are
real, distinct method definitions this registry never modeled at all --
this project's own established "invisible to a plain TDEF/DEF bytecode
walk" gap shape, a fourth instance alongside `attr_reader`/`writer`/
`accessor`, `Struct.new`, and `SDEF`/`SCLASS`.

**Confirmed NOT currently exploitable**, the same rigor this file's own
prior "checked but not live" findings (the `NATIVE_SRCS` `'<native>'`-
owner-scope gap, `alias_method`) already establish: "LCF" (the bare
module, as distinct from `LCF::File`/`Database`/`MapTree`/`MapUnit`/
`SaveData`/`MoveCommand`/`EventCommand`/`Tree`/`Sections`/`Array1D`/
`Array2D`) is never itself a compiled owner in any of the three real
gems' own `owners:` lists (confirmed directly against
`BC2CPP_COMPILED_GEMS`), so `compile_send`'s own already-established
owner-not-emitted guard already falls back to ordinary `mrb_funcall`
dynamic dispatch for every real `module_function`-installed call site in
this closed world today, with or without this fix -- confirmed directly
against the real generated `lcf_compiled_gen.cpp`, whose real
`LCF::File#to_lcf` body already reads `// POLY :write_ber -- real
dynamic dispatch...` / `// POLY :binstr -- real dynamic dispatch...`,
never a direct call, both before and after this fix.

**The fix** (`tools/bc2cpp/bc2cpp.rb`'s `build_registry`): recognizes
`module_function` as a third case alongside `private`/`protected`/
`public` and `attr_reader`/`writer`/`accessor`, reusing the same
`collect_loadsym_names` backward-`LOADSYM`-argument scan both existing
cases already share. For each named method, registers a synthetic
`MethodDef` (`irep: nil`) under the distinct `"Owner.singleton"`
pseudo-owner `SDEF`/`SCLASS` already use elsewhere in this file (can
never collide with or be selected by `ONLY_OWNERS`, which only ever
names real Ruby constant paths) -- deliberately does **not** touch the
already-registered instance-level `MethodDef`'s own visibility, unlike
`private`'s retroactive-marking case immediately above it, since real
mruby genuinely does not privatize it. This can only ever turn an
unsound MONO into a correctly cautious POLY, never remove a genuinely
sound one, the same one-directional-safety guarantee every other
synthetic-`MethodDef` fix in this file already carries.

One real, verified limitation the fix inherits rather than
re-introduces: the 16-name `module_function` call site itself exceeds
mrbc's own literal argument-count encoding (confirmed directly against
the real disassembly: `SSEND R1 :module_function n=*`, the same
`CALL_MAXARGS` splat sentinel this file's own `Game::Enemy`
15-argument-`attr_reader` finding already documents hitting, versus the
6-name call site's own plain `n=6`) -- outside `collect_loadsym_names`'
own `n=(\d+)`-only counting, so this fix silently registers nothing for
that one call site's own 16 names specifically. Not a new gap this fix
introduces (the exact same limitation already exists, and was
explicitly left unfixed as separate scope, for `attr_reader`), and not
currently exploitable for the same owner-not-emitted reason as the
6-name call site regardless.

**Verified for real, the same way every other `bc2cpp.rb`-touching round
in this file is:** re-ran all three gems' real `bc2cpp.rb` invocations
(`ONLY_OWNERS`/`OTHER_OWNERS`/`OTHER_DECLS_HEADER`/`NATIVE_SRCS`/
`SKIP_UNSUPPORTED` computed exactly the way each real `mrbgem.rake`
does) before and after the fix: **all three gems' own generated `.cpp`
files are byte-identical before and after** (a real diff, not assumed --
the fix only ever adds new registry entries under a pseudo-owner no
`ONLY_OWNERS`/`OTHER_OWNERS` list anywhere names, so it cannot change
what gets emitted), confirming zero live effect on any of the 60
already-shipped owners, exactly as the "not currently exploitable"
analysis above predicts. The only diagnostic-listing change anywhere is
the expected one: `:var_max`/`:var_min`/`:level_max`/`:pc_hp_max`/
`:npc_hp_max`/`:exp_default` flip from `MONO (1 def: LCF)` to `POLY
(2 defs: LCF, LCF.singleton)` in the real whole-program registry dump
(the 16-name call site's own names do not flip, for the `n=*` reason
above). Re-ran the full exhaustive registration/arity/visibility
cross-diff and the empty-method-name grep against all three
freshly-regenerated files after the fix: same result as before the fix
in every respect -- 893/893 methods matched, zero arity/visibility
mismatches, zero empty-method-name matches. Re-ran `g++ -fsyntax-only
-Wall -Wextra -Winfinite-recursion` (with `OTHER_DECLS_HEADER` wired)
and `g++ -c` against all three real, post-fix `register.cxx` files:
zero errors, zero `-Winfinite-recursion` warnings, same object-file
symbol counts as before the fix (79 / 1662 / 87). `ruby -c
tools/bc2cpp/bc2cpp.rb`: syntax OK. This worktree's own uninitialized
`3rd/mruby`/`3rd/lvgl` (the same recurring fresh-worktree gap this file
already documents dozens of times) means the real, full
`cmake`/`rake`-driven engine build and a Renode/on-device runtime diff
were not run this round -- left for a correctly-configured checkout, the
same honest gap every prior round that hit this exact environment
limitation already records.

## Follow-up: Game::Interpreter partial coverage (round 28)

`Game::Interpreter` (`mruby-rpg2k/mrblib/interpreter.rb`, plus a separate
4-method reopening in `mruby-rpg2k/mrblib/game/battle_support.rb`) was
already registry-visible before this round -- `bc2cpp`'s own whole-program
registry walk always covers every gem's mrblib regardless of any single
compiled gem's own `owners:` list (see `tools/bc2cpp/compiled_gems.rb`'s
own `closed_world_mrblib_srcs` comment), so it was already used for
MONO/POLY devirtualization soundness elsewhere in this file (the
`Game::Interpreter#switches` `attr_reader`-collision check several
follow-ups up is the clearest example) -- but it had never been added as
a real *emission* owner in any compiled gem, called out repeatedly in this
file as "legitimately too large to fully cover in one round." This round
adds it to `mruby-rpg2k-compiled`'s own `owners:` for the first time.

**Environment, built fresh in this round's own worktree** (the same shape
this file's own `RGSS::Tilemap`/`Game::Rng`/`RGSS::Font`/battle_support.rb
follow-ups already document, extended one step further): `git submodule
update --init` for all nine `3rd/*` submodules this project's default
desktop build needs (`mruby`, `mruby-marshal`, `mruby-onig-regexp`,
`mruby-stringio`, `uni-algo`, `stb`, plus `SDL`, `SDL_mixer`, `effekseer`,
`gflags`, `inicpp`, `lvgl`, `mgem-list`, `ng-log`, `quickjs`, each
recursively for their own nested submodules), the nine `patches/*.patch`
files applied by hand via `scripts/apply_mruby_patch.bash` (still no
automatic hook for this), then a real host `mrbc` built by running `rake`
from *inside* `3rd/mruby` itself with `HOST_CXX=c++` (`mruby 4.0.0`, built
clean). `tools/bc2cpp/bc2cpp.rb` was run directly against that real
`mrbc`, with `ONLY_OWNERS`/`OTHER_OWNERS`/`OTHER_DECLS_HEADER`/
`NATIVE_SRCS`/`SKIP_UNSUPPORTED` computed exactly the way each real
`mrbgem.rake` computes them, over the whole `mruby-rpg2k`+`mruby-lcf`+
`mruby-rgss` closed world -- both with `SKIP_UNSUPPORTED=1` (the real
build's own setting) and `SKIP_UNSUPPORTED=0` (to read each skipped
method's own real `#error` marker directly, not just its name). Unlike
several recent prior rounds, this round's own worktree *did* reach the
real `build_config.rb` + `cmake`/`ninja` pipeline end to end (see
"Verified for real" below) -- the missing piece the last several rounds'
own environment-limitation writeups all cite (`3rd/mruby`/`3rd/lvgl`
uninitialized) turned out to be reachable this round simply by initializing
every submodule the default desktop target needs, plus fetching and
hash-verifying (against the exact SHA-256 values `flake.nix`/
`scripts/native-build-without-nix.bash` already pin) the two `cp932_table`/
`jis0208_table` Unicode.org mapping files `mruby-lcf`'s own `mrbgem.rake`
needs and has no automatic fetch step for.

**207 real bytecode-defined methods, 173 compiled and registered, 34 stay
interpreted for five distinct, individually confirmed reasons** (never
guessed from a shared shape -- every one below was checked against its own
real `#error` marker with `SKIP_UNSUPPORTED=0`):

- **20 end in a real Ruby block** (`BLOCK`/`SENDB`): `#restore_call_stack`,
  `#resume_inn`, `#key_input_result`, `#do_jump_label`,
  `#do_control_switches`, `#do_control_vars`,
  `#do_control_vars_range_variable`, `#do_change_exp`, `#do_change_level`,
  `#queue_level_up_messages`, `#do_change_hp`, `#do_change_mp`,
  `#do_full_heal`, `#do_simulated_attack`, `#do_change_condition`,
  `#do_change_class`, `#do_change_battle_commands`, `#do_change_params`,
  `#do_change_skills`, `#do_change_equipment` -- every one of these
  iterates a party/target/actor list (`actors.each`, `party.each`, ...),
  the same already-established out-of-scope shape as every other
  `BLOCK`/`SENDB` gap in this file. (`#resume_inn`'s own real marker is
  `SENDB` alone, no preceding `BLOCK` -- a block already captured upstream
  rather than a literal `do...end` at this call site; same underlying
  "this compiler has no `SENDB` case" gap either way.)
- **8 end in a real `rescue StandardError` clause** (`EXCEPT`/`RESCUE`/
  `RAISEIF`): `#resolve_call`, `#do_call_common_event`,
  `#common_event_commands`, `#do_store_terrain_id`, `#do_store_event_id`,
  `#do_fadeout_bgm`, `#do_play_memorized_bgm`, `#play_audio` -- the same
  already-established out-of-scope shape as `MapWorld`'s/`VehicleWorld`'s
  own `#play_sound`.
- **3 hit a real, still-unmodeled opcode this compiler has never had a
  `when` case for at all**: `#update`, `#skip_to`, `#do_show_choices` all
  emit `#error unhandled opcode JMPUW`. Read `3rd/mruby/src/vm.c`'s own
  `OP_JMPUW` handler directly before writing this up, rather than guessed
  from the name: it is `unwind_and_jump_to(a)` per `ops.h`'s own comment --
  a jump that has to unwind through an active `ensure`/`break`
  catch-handler region on its way to its target, mrbc's own compiled shape
  for a `break`/early-`return` reachable from inside one of these methods'
  own `until`/loop bodies (`#update`'s own `until @waiting ... break if
  ... end`, confirmed directly against the real disassembly). Left unfixed
  -- no new `bc2cpp.rb` opcode work this round -- a real, confirmed-safe
  structural gap for a future round, the same discipline this file's own
  `RETSELF`/`Game::MessageConfig#load_h` writeup already established for a
  different never-modeled opcode.
- **2 send a keyword-argument-heavy call `compile_send` already refuses on
  sight**: `#do_show_picture` (`.show_picture` with 11 keyword arguments,
  real marker `SEND/SSEND :show_picture has a splat and/or keyword
  argument list (n=1|nk=11)`) and `#do_change_parallax` (`.set_parallax`
  with 7 keyword arguments, `n=0|nk=7`) -- the same already-established
  out-of-scope shape this file's own third-severe-bug follow-up (the
  silently-dropped-keyword-argument fix) documents at the root.
- **1 has a real optional argument**: `#start_random_battle` -- the same
  already-established non-mandatory-arity gap as every other interpreted
  `#initialize` in this codebase (`#start_random_battle` is one of two
  names this class's own bare `private` mode-switch retroactively
  re-exposes with `public :start_random_battle`; it stays interpreted
  regardless of its own visibility).

**A real, previously-undiscovered gap in `drop_unsafe_embeddings` itself,
found chasing down `Game::Interpreter#@frame_steps` -- this round's own
real severe-bug finding, not merely a coverage gap.** `#initialize(state)`
has pure mandatory arity and compiles clean, so the existing
`drop_unsafe_embeddings` gate does not refuse this class outright, and the
raw `IvarLayout` analysis proposes exactly one embeddable ivar:
`@frame_steps` (a provably-Fixnum this-frame step budget, set in
`#initialize`/`#reset_frame_steps` and read/incremented in `#update`'s own
`break if @frame_steps >= MAX_STEPS` / `@frame_steps +=
step_cost(cmd.code)`). But `#update` is one of the three `JMPUW` gaps
above -- it never compiles. Had `@frame_steps` been embedded anyway (the
existing gate only ever checked `#initialize`'s own compileability, never
any *other* method touching the same ivar), every real `#update` call
after the first `#initialize` would have read a permanently-nil
`iv_tbl["@frame_steps"]` instead of the value `#initialize` actually set:
`mrb`'s own `struct RData` (`3rd/mruby/include/mruby/data.h`) carries a
real `struct iv_tbl *iv` field, entirely separate from the `void *data`
pointer this compiler's embedded struct lives behind -- confirmed directly
against the real struct definition, not assumed. A compiled
`#initialize`'s own embedded-field write never touches that `iv_tbl` at
all, so a still-interpreted method's own ordinary `SETIV`/`GETIV`
bytecode for the very same ivar name reads/writes a completely different,
never-synchronized storage location on the same object -- immediate,
deterministic breakage (`nil >= MAX_STEPS` raising `NoMethodError`) the
first time any real event ever ran under this build, not a subtle,
load-bearing-only-in-rare-cases bug.

**Confirmed this exact bug class was already live, not merely
hypothetical, in already-shipped code.** Before fixing the gate,
`Game::Transition`'s own `@width`/`@height` (`mruby-rpg2k/mrblib/game.rb`)
were real embedded struct fields on a `Game__Transition_ivars*` RData
payload, already built and shipped by an earlier round. Six of
`Game::Transition`'s own real methods -- `#block_rects`, `#blind_rects`,
`#vertical_stripe_rects`, `#horizontal_stripe_rects`, `#clip`,
`#compute_block_order`, all genuine Ruby-block users, all already known
and documented as staying interpreted -- also read one or both of these
ivars, entirely outside any compiled codegen's own view. `#blind_rects`'s
own `bands = @height / BLIND_BAND` reads `@height` at the method's own top
level, *before* its own trailing `bands.times do |i| ... end` block even
starts -- visible to even a naive same-irep-only scan. `#clip`'s own
`rects.each do |x, y, w, h| ... next if ... x >= @width || y >= @height
...  end` reads both `@width` and `@height`, but *only* inside that
block's own separate child irep -- invisible to a scan of `#clip`'s own
top-level irep alone (confirmed directly against the real generated
output: `#clip`'s own top-level irep is 6 instructions -- build the
Array, `MOVE` the argument, `#error unhandled opcode BLOCK` -- and never
itself mentions either ivar). Since none of these 6 methods ever compiles,
every one of them keeps running `mruby-rpg2k`'s own interpreted mrblib
body, which -- exactly like `Game::Interpreter#update` above -- reads and
writes the *ordinary* dynamic `iv_tbl`, never the embedded struct field a
compiled `#initialize` actually wrote. Every real call to any of these 6
methods against an already-constructed `Game::Transition` would have read
a permanently-nil `@width`/`@height` instead of the real value --
`#clip`'s own `x >= @width` raising `NoMethodError` (`nil` has no `>=`)
the first time any real screen transition ever clipped a rect. A live
crash in already-merged, already-shipped code enabling this gem, not a
missed optimization and not this round's own new mistake -- this bug
predates this round entirely and was only ever caught because fixing it
for `Game::Interpreter` required making the underlying check general.

**The fix** (`tools/bc2cpp/bc2cpp.rb`): a new `every_accessor_compiles?`
check, called from `drop_unsafe_embeddings` alongside the existing
`natively_exposed?` check, for every candidate ivar. For a given owner and
ivar name, it walks every real `MethodDef` under that owner and, for each
one whose own irep (or any irep nested inside it -- a block literal's own
separate child irep, `irep.reps[idx]`, walked recursively via a new
`irep_subtree_touches_ivar?` helper) contains a `SETIV`/`GETIV` for this
exact ivar, requires that method's own `compiles_clean?` to be true; a
single real touch site inside a method that does not compile poisons the
whole ivar back to the ordinary dynamic `iv_tbl`, the same one-directional
"can only make embedding more conservative, never less" safety guarantee
every other synthetic-`MethodDef`/`drop_unsafe_embeddings` fix in this
file already carries. Recursing into nested child ireps (not just the
method's own top-level irep) is the one non-obvious part: mrbc compiles a
block literal's own body into a genuinely separate irep, so a plain scan
of the enclosing method's own `irep.instructions` alone -- the first,
narrower version of this fix this round actually tried first -- still let
`Game::Transition#clip`'s own `@width` read slip through unnoticed
(confirmed for real: an intermediate build of this fix correctly dropped
`@height` via `#blind_rects`'s own top-level read but still left `@width`
embedded, until the recursive child-irep walk was added). Hit one real,
separate implementation bug getting there: `every_accessor_compiles?`'s
first draft iterated `@registry.each_value` directly while calling
`compiles_clean?` inside that same iteration -- `@registry` is a
`Hash.new { |h, k| h[k] = [] }`, so a plain read of a not-yet-seen method
name anywhere inside `compiles_clean?`'s own real compile attempt (e.g.
`natively_exposed?`'s own `@registry[name]`) auto-vivifies a new key as a
side effect, mutating the very hash being enumerated -- a real, reproduced
"can't add a new key into hash during iteration" `RuntimeError` the first
time this ran against the whole closed world. Fixed by snapshotting
`@registry.values` into a plain, disconnected Array before iterating,
decoupling the walk from any nested mutation.

**Verified the fix regresses nothing already shipped.** Re-ran all three
gems' real `bc2cpp.rb` invocations before/after the fix, with
`Game::Interpreter` still excluded from `owners:` (isolating the fix's own
effect from this round's coverage addition): `mruby-lcf-compiled`'s and
`mruby-rgss-compiled`'s own generated output is **byte-identical**
before/after. `mruby-rpg2k-compiled`'s own output differs in exactly one
place: `Game::Transition`'s own `Game__Transition_ivars` struct loses
`@width`/`@height` (and, since nothing else on this class was ever
embedded, disappears entirely, along with the class's own
`MRB_SET_INSTANCE_TT` call), and the 13 real methods that reference either
ivar (`#initialize`, `#block_grid_cols`, `#visible_rects`,
`#capture_ops`, `#scroll_offset`, `#vertical_split_ops`,
`#horizontal_split_ops`, `#cross_split_ops`, `#zoom_rect`,
`#border_to_center_rect`, `#center_to_border_rect`, `#around`, plus
`#clip`/`#blind_rects`/etc. themselves, which were never compiled either
way) switch from `DATA_PTR(self)` struct-field access to plain
`mrb_iv_get`/`mrb_iv_set` -- every one of those methods' own
arity/visibility/registration is completely unaffected, confirmed by
re-running the exhaustive registration cross-diff (below) against the
unchanged part of the output too. `Game::Screen`'s own 10 embedded fields
and `RPG2k::Scene::VehicleWorld`'s own `@type` are byte-identical
before/after -- neither is touched by any currently-uncompiled method
anywhere in the closed world, confirmed directly rather than assumed.
`mruby-rpg2k-compiled/src/register.cxx` itself is fixed accordingly: the
stale `MRB_SET_INSTANCE_TT(transition, MRB_TT_DATA)` call is removed, and
that class's own registration-block comment rewritten to document the
real bug and fix in place of the documentation-drift note it replaces.

**`Game::Interpreter`'s own real MONO/POLY registry soundness, checked and
confirmed correct.** `#party`/`#switches`/`#variables` (all three
`private`, all three a bare `@state.x`) share their own bare name with
`Game::State`'s own public `attr_reader :party, :switches, ...,
:variables` -- exactly the collision shape a much earlier follow-up in
this file first found and fixed at the registry level, and the same one a
later follow-up confirmed was NOT yet live specifically for `:switches`
because `Game::Interpreter` was not yet a compiled owner at all. Now that
it is, the real current registry dump confirms `:party`/`:switches`/
`:variables` all correctly show `POLY (2 defs: Game::State,
Game::Interpreter)` -- every real call site anywhere in the closed world
sending any of these three names still goes through ordinary
`mrb_funcall` dynamic dispatch, never a direct call into the wrong
class's own `_impl`.

**Visibility, cross-checked against the real diagnostic, not inferred
from source position alone.** A bare `private` (mruby-rpg2k/mrblib/
interpreter.rb) sits partway through the class body and stays in effect
through the end of it, except two names explicitly reopened with `public
:name` immediately afterward (`public :start_random_battle`, `public
:start_death_handler`) -- `#start_random_battle` never compiles anyway
(non-mandatory arity, above), but `#start_death_handler` does, and the
real diagnostic confirms it correctly carries no `[private -- ...]` tag,
registered with plain `mrb_define_method` below. `#initialize` itself is
*also* always private, the same real interpreter special case (`mruby`'s
own `src/class.c` forces it unconditionally at `def`-time) as every other
compiled `#initialize` in this file, not from the bare `private` above
(which sits well after `#initialize`'s own `def`).

**Verified for real, not just self-reported:**

- Ran the real `tools/bc2cpp/bc2cpp.rb` generation for `mruby-rpg2k-
  compiled` with `Game::Interpreter` added to `owners:`, exactly the way
  the real `mrbgem.rake` computes every env var. Inspected the generated
  `.cpp` and the diagnostic output directly: 173 `Game::Interpreter`
  entries in `== compiled entry points ==`, 34 in `== skipped
  (unsupported...) ==`, matching 207 real `def`s (203 in
  `interpreter.rb` + 4 in the `battle_support.rb` reopening).
- `grep -c 'mrb_funcall(M, [a-z0-9]*, "", '` (the project's own
  empty-method-name bug detector) against all three real, freshly
  regenerated `*_gen.cpp` files: **zero** everywhere, as required.
- **Exhaustive registration cross-diff**, the same discipline the last
  full-sweep round established: every `(owner, method_name)` pair the
  diagnostic reports for `Game::Interpreter` against every
  `mrb_define_(private_)method` call actually present in
  `register.cxx`'s new block, cross-checking arity and visibility too --
  **173/173 matched, zero mismatches on either axis**.
- `nm -C` on a real, freshly compiled `register.cxx` object file: 346
  `Game__Interpreter_*` symbols (173 entries x 2, an entry wrapper plus
  its own `_impl`), and zero remaining `Transition_ivars`-named symbols
  anywhere (confirming the struct really is gone, not just undocumented).
  A direct `grep -c` for `MRB_SET_INSTANCE_TT(` call sites in
  `register.cxx` (excluding comments) finds exactly 2 -- `screen` and
  `vehicle_world` -- matching the real diagnostic's own "classes needing
  `MRB_SET_INSTANCE_TT`" list precisely (`Game::Transition` and
  `Game::Interpreter` both correctly absent).
- `clang-format -i` then `clang-format --dry-run --Werror` on
  `register.cxx`: clean.
- `g++ -std=gnu++17 -Wall -Wextra -Winfinite-recursion -fsyntax-only` and
  a real `g++ -c` against all three gems' real, freshly regenerated
  `register.cxx` files (with `OTHER_DECLS_HEADER` wired the same way each
  real `mrbgem.rake` wires it): **zero errors** in all three, only the
  same pre-existing, unrelated `-Wunused-but-set-variable`/
  `-Wunused-parameter` noise this file already documents in many earlier
  rounds.
- **Reached the real, full `build_config.rb` + `cmake`/`ninja` pipeline
  end to end, unlike several recent prior rounds that were blocked by an
  uninitialized worktree** -- `RPGMAKER_BC2CPP=1 cmake ..` configured
  clean (`SDL2`/`SDL2_mixer` found via the system's own real dev
  packages, no missing-dependency failures), and `RPGMAKER_BC2CPP=1
  ninja mruby/host/lib/libmruby.a` (after fetching and SHA-256-verifying
  the two Unicode.org mapping tables `mruby-lcf`'s own build needs, per
  `scripts/native-build-without-nix.bash`'s own pinned hashes) built the
  real host `libmruby.a` end to end: **exit 0, zero `error:` lines
  anywhere in the full build log** (the only `Error`-shaped text is
  literal Ruby exception class names -- `NoMemoryError`, `TypeError`,
  ... -- inside the real generated source, not compiler diagnostics),
  the "Build summary" listing `mruby-lcf-compiled`/`mruby-rgss-compiled`/
  `mruby-rpg2k-compiled` all present in the `host` config's own included-
  gems list. `mruby-rpg2k-compiled/src/register.cxx` (this round's own
  edits included) really compiled (`CXX .../register.cxx ->
  .../register.o`, no warnings) and its own `register.o` is really one of
  the object files the final `ar` invocation links into
  `build/mruby/host/lib/libmruby.a` -- confirmed directly by grepping the
  real `ar` command line for it, not assumed. `nm -C` on the real,
  finished `libmruby.a` (94,570,508 bytes): **346 `Game__Interpreter`
  symbols** (173 entries x 2, an entry wrapper plus its own `_impl` each),
  matching the standalone `g++ -c`/`nm` check above exactly.

## Follow-up: Game::State (lsd_io.rb save/load) coverage investigation (round 28)

A dedicated round was asked to cover `mruby-rpg2k/mrblib/game/lsd_io.rb`
-- `Game::State`'s own separate ~1,747-line reopening that adds the real
`.lsd` (RPG_RT-compatible) save/load serializers, distinct from
`mrblib/game.rb`'s own main class body and its Marshal `#to_h`/`.load`
round-trip. **Conclusion up front: zero registration changes.** Reading
the real source end to end found this file defines exactly 12 real
bytecode-defined methods -- 3 instance methods (`#to_lsd`, `#bgm_chunk`,
`#se_chunk`) and 9 `def self.foo` class methods
(`.tile_replacement_bytes`, `.tile_replacement_hash`,
`.build_event_exec_state`, `.read_event_exec_frames`, `.from_lsd`,
`.restore_pictures`, `.ole_now`, `.bgm_from_chunk`, `.se_from_chunk`) --
and every one of the 3 instance methods was already correctly resolved
by an earlier round (this ADR's own "`Game::State`'s own real RData
embedding" follow-up, several rounds up): `#bgm_chunk`/`#se_chunk` are
already registered and compiling clean, and `#to_lsd` was already
correctly documented as blocked by its own non-mandatory arity. What
this round found and fixed was a real, confirmed documentation gap, not
a missing registration: neither `register.cxx` nor `compiled_gems.rb`
anywhere named or explained the file's own 9 `self.` class methods --
they simply never appeared in either file's own method-count accounting
at all (the "32" total both files already cite for `Game::State` only
ever counted `CLASS`/`MODULE`/`TDEF`-walked instance methods, and these
9 are `SDEF`-defined singleton methods, a structurally separate bucket
-- see below).

**Environment, built fresh in this round's own worktree.** This
worktree's own `3rd/*` submodules started uninitialized (the same
recurring fresh-worktree gap this file already documents dozens of
times) -- `git submodule update --init --recursive` (all 15, ~2.5
minutes, no network gap this time since the main checkout had already
fetched every submodule's objects). Rather than hand-apply
`patches/*.patch` and hand-build a host `mrbc` the way several earlier
investigation-only rounds did, this round ran the project's own real
`cmake ..` configure step directly (which applies every `mruby-*.patch`
itself as part of its own generator rules) plus `ninja
mruby/host/lib/libmruby.a` with `RPGMAKER_BC2CPP=1` set -- the exact
command this round's own task description specified. The only
environment gap hit: `mruby-lcf/cp932_to_unicode.rb`'s own build-time
codegen needs `$cp932_table`/`$jis0208_table` env vars pointing at two
Unicode mapping tables (docs/adr/0058's/0111's/0130's own already-
documented prerequisite) -- unset by default in a fresh worktree, but
the *main checkout* already had them cached at
`.native-build-tables/{bestfit932.txt,JIS0208.TXT}` (fetched once by an
earlier `scripts/native-build-without-nix.bash` run), so this round
pointed both env vars at that existing cache rather than re-downloading
it. With those two vars set, the real `cmake ..` configure and the real
`ninja mruby/host/lib/libmruby.a` (which builds and links all three
compiled gems, `mruby-lcf-compiled`/`mruby-rpg2k-compiled`/
`mruby-rgss-compiled`, through their own real `mrbgem.rake`-driven
`bc2cpp.rb` invocations) both ran end to end for real, not simulated.
`tools/bc2cpp/bc2cpp.rb` was also run directly by hand (via a small
script requiring `compiled_gems.rb` and replicating
`mruby-rpg2k-compiled/mrbgem.rake`'s own env computation exactly --
`ONLY_OWNERS`/`OTHER_OWNERS`/`NATIVE_SRCS` from the real, current
`BC2CPP_COMPILED_GEMS`/`closed_world_mrblib_srcs`/`core_native_srcs`,
never hand-copied) against the real host `mrbc` the real build produced,
to read the `== compiled entry points ==` listing, the whole-program
MONO/POLY registry dump, and individual `#error` markers directly.

**`#bgm_chunk`/`#se_chunk` re-confirmed already correct, not merely
trusted from `register.cxx`'s own existing `mrb_define_method` calls.**
Both are real, mandatory-arity-1 instance methods (a hash-field read, a
few `||` defaults, one write to the return `LCF::Array1D` -- no block,
no `rescue`, no `super`), and the real `== compiled entry points ==`
listing lists both (`Game__State_bgm_chunk`/`Game__State_se_chunk`,
arity 1, not private) exactly matching the two existing `mrb_define_method(M,
state, "bgm_chunk"/"se_chunk", ..., MRB_ARGS_REQ(1))` calls already in
`register.cxx`. `nm -C` on the real, freshly-built `libmruby.a` confirms
both `Game__State_bgm_chunk_impl`/`Game__State_se_chunk_impl` present and
externally linked (`T`, not `t`/`U`). `#to_lsd` re-confirmed blocked by
its own real, unchanged `#error` marker: `#error Game::State#to_lsd has
non-mandatory arguments (optional/rest/keyword/block) -- not in this
prototype's supported subset` (its own 5 all-optional arguments --
`save_count = 1, timestamp = nil, save_slot = 1, db = nil, map_tree =
nil` -- the same finding this ADR's own ninth-round follow-up already
recorded).

**The 9 `def self.foo` class methods, checked individually, not assumed
uniform.** The real whole-program registry dump lists all 9 under the
synthetic `"Game::State.singleton"` pseudo-owner this ADR's own
`RGSS::Bitmap`/`RGSS::Font` follow-ups already established (`MONO
:from_lsd (1 def: Game::State.singleton)`, `MONO :ole_now (1 def:
Game::State.singleton)`, and so on for all 9) -- confirming the registry
itself *does* see these methods (for MONO/POLY devirtualization
soundness: e.g. `:bgm_chunk` stays a clean `MONO (1 def: Game::State)`
distinct from the separate `:bgm_from_chunk` name, so no naming
collision exists between the instance and class method sides of this
file). But none of the 9 can ever become a real emission target, fully
independent of whatever opcode gap its own body might also have --
re-verified directly for this class, not assumed by analogy to the
`RGSS::Font` finding: running `bc2cpp.rb` with `Game::State.singleton`
added to `ONLY_OWNERS` (alongside every one of `mruby-rpg2k-compiled`'s
real 44 owners) and `SKIP_UNSUPPORTED=0` (which forces every other
target's own gaps to emit a real `#error` stub rather than being silently
dropped) still produces **zero** output anywhere in the ~20,000-line
generated file for any of the 9 names -- no forward declaration, no
`#error` stub, nothing at all. This is the same "structurally incapable
of ever emitting a real singleton-method entry point" limitation the
`RGSS::Font` follow-up already named, now directly re-confirmed against
a second, independent class rather than trusted as a general claim.

Independently of that structural gate -- real information for a future
round that ever lifts it -- each of the 9's own body was read and
checked against its own real gap shape, the same discipline this ADR
already holds every instance-method finding to:

- `.tile_replacement_bytes(subs)`, `.tile_replacement_hash(bytes)`,
  `.build_event_exec_state(frames)` and `.restore_pictures(state,
  pictures)` each end in a real Ruby block (`subs.each { |old_id, new_id|
  ... }`, `bytes.each_with_index { |v, i| ... }`,
  `frames.each_with_index do |f, i| ... end`, `pictures.each do |id, pic|
  ... end` respectively) -- the same established BLOCK/SENDB
  out-of-scope shape this file already documents dozens of times over.
- `.read_event_exec_frames(exec_state)` combines a real block
  (`stack.each do |_, frame| ... end`) with a real `rescue StandardError
  => e` clause -- the same combined shape this ADR's own ninth-round
  follow-up already named for `#seed_screen_transitions`/
  `#seed_vehicle_positions`.
- `.ole_now` has a real `rescue StandardError` clause alone (no block,
  no arguments at all) -- `Time.now.to_i / 86400.0 + OLE_EPOCH_OFFSET
  rescue StandardError NO_CLOCK_TIMESTAMP`, a bare method-level rescue.
- `.from_lsd(db, save)` -- by far the largest of the 9, the inverse of
  `#to_lsd` -- has pure mandatory arity (2 required arguments, no
  `super`) but is saturated with real Ruby blocks throughout its own
  ~460-line body (`ids.each_index do |i| ... end`,
  `(save[108] || []).each do |aid, sa| ... end`,
  `SYSTEM_BGM_SAVE_FIELD.each do |slot, field| ... end`, several more),
  so it would fail on the same established BLOCK/SENDB gap even if the
  `.singleton` emission gate were ever lifted.
- `.bgm_from_chunk(chunk)` and `.se_from_chunk(chunk)` are the only two
  of the 9 with no block, no `rescue`, and pure mandatory arity (1
  argument each) -- a `return nil` guard, a couple of hash-field reads
  with `||` defaults, one hash-literal return. The exact same
  straight-line shape `#bgm_chunk`/`#se_chunk` (their own instance-method
  callers, both already compiling) already use. These two are the
  closest either file gets to demonstrating the `.singleton` emission gap
  is the *only* thing blocking a real class method: were this compiler
  ever extended to emit a `.singleton`-owned entry point at all (out of
  scope for this round -- no already-shipped target has ever needed it,
  and the mechanism-design question of how such a method's receiver-less
  call site would even devirtualize is a separate, larger piece of work),
  `.bgm_from_chunk`/`.se_from_chunk` would very likely compile clean on
  the first try.

**Both `register.cxx` and `compiled_gems.rb` were updated** to name and
explain all 9 methods next to `Game::State`'s existing writeup (the same
documentation-completeness-only fix this ADR's own
"Game::Actor/Game::Party (battle_support.rb) coverage" follow-up several
rounds up already used as precedent for a round whose real finding was
"already fully covered, the comment just didn't say so correctly") --
`clang-format -i` then `clang-format --dry-run --Werror` run clean on
`register.cxx` afterward. Confirmed by diff that this round's own edit to
`register.cxx` is comment-only: zero `mrb_define_method`/
`mrb_define_private_method` call sites added, removed, or reordered (`git
diff` shows 21 inserted lines, all inside `//` comments; a grep for
`mrb_define` across the diff's own added/removed lines matches zero
times). No changelog fragment was added -- this round registered nothing
new, so the ADR section here is the intended record, matching this
file's own established convention for an investigation-only round (see
the `RGSS::Font investigated, and NOT added` follow-up for the prior
precedent).

**Verified for real, against the actual real build, not just the
standalone diagnostic.** Beyond the direct `ONLY_OWNERS`-inclusive
`Game::State.singleton` check above: the real, opt-in
`RPGMAKER_BC2CPP=1` build (`cmake ..` then `ninja
mruby/host/lib/libmruby.a`, this round's own real worktree, `cp932_table`/
`jis0208_table` pointed at the main checkout's own cached tables) succeeds
end to end -- **zero** `error:` matches and **zero** `warning:` matches
anywhere in the full build log, and a fresh, 93MB `libmruby.a` was
produced. `nm -C` on that real archive shows exactly 23 `Game__State_*_impl`
symbols (matching "23 of its own 32" exactly, unchanged from before this
round) including `Game__State_bgm_chunk_impl`/`Game__State_se_chunk_impl`,
both present and externally linked (`T`), and 46 total `Game__State_`
symbols (23 `_impl` plus 23 matching `static` wrappers, a clean 1:1
pairing). `grep -c 'mrb_funcall(M, [a-z0-9]*, "", '` (the project's own
empty-method-name bug detector) against all three real, freshly
regenerated `*_gen.cpp` files (`mruby-lcf-compiled`, `mruby-rpg2k-compiled`,
`mruby-rgss-compiled`): **zero** in every one, as required. Did not run
the full desktop/SDL/effekseer/lvgl engine link or a Renode/on-device
diff -- out of scope for a change that touches zero registration and
whose only executable-relevant surface (`mruby/host/lib/libmruby.a`,
which every compiled gem's own generated code links into) was the real
target this round's own build command already exercised end to end.

## Follow-up: adversarial bug-hunt sweep (round 28)

A second dedicated adversarial bug-hunt round, not a coverage round,
explicitly scoped to find *different* kinds of issues than round 27's own
exhaustive per-method registration/arity/visibility cross-diff: other
Ruby method-definition mechanisms besides the seven this file already
documents as invisible to `build_registry` (`attr_reader`/`writer`/
`accessor`, `Struct.new`, `SDEF`, `SCLASS`-at-class-level, `alias_method`,
`module_function`); any interaction between round 27's own
`module_function` fix and devirtualization/embedding specifically; a
field-list/order/type audit of every currently-embedded `RData` struct,
focused on the most recently added owners; and a search for any generated
method whose behavior could silently diverge from real interpreted mruby
semantics.

**Environment, built fresh in this worktree.** No pre-built host `mrbc`
existed anywhere on this machine (unlike several prior rounds, which found
one already built in a sibling checkout) and every `3rd/*` submodule was
uninitialized. `git submodule update --init 3rd/mruby 3rd/mruby-marshal
3rd/mruby-onig-regexp 3rd/mruby-stringio 3rd/uni-algo 3rd/stb`, the same
seven `patches/mruby-*.patch` files applied by hand via
`scripts/apply_mruby_patch.bash` (all seven applied cleanly, none already
applied, none rejected), then a real host `mrbc` built by running `rake`
from *inside* `3rd/mruby` itself with `HOST_CXX=c++`
(`PATH=/opt/ruby-3.3.6/bin:$PATH` -- the same `Dir.pwd == MRUBY_ROOT` /
C++-linker-for-C++-exception-runtime reasoning this ADR's own
`RGSS::Tilemap` follow-up already documents in detail) -- built clean,
`mruby 4.0.0`. `tools/bc2cpp/bc2cpp.rb` was then run directly against that
real `mrbc`, both as one whole-program unrestricted diagnostic (no
`ONLY_OWNERS`, full `NATIVE_SRCS`) and as three separate per-gem runs each
replaying its own real `mrbgem.rake`'s exact env-var computation
(`ONLY_OWNERS`/`OTHER_OWNERS`/`OTHER_DECLS_HEADER`/`NATIVE_SRCS`/
`SKIP_UNSUPPORTED`, all read programmatically from the current, real
`tools/bc2cpp/compiled_gems.rb` rather than hand-copied) -- every number
and generated-code excerpt quoted below came from these real runs. The
real `RPGMAKER_BC2CPP=1` + `cmake`/`ninja` engine build named in this
round's own task brief was not reachable: `3rd/SDL`, `3rd/SDL_mixer`,
`3rd/effekseer`, `3rd/lvgl`, `3rd/quickjs`, and `3rd/ng-log` are all large
submodules genuinely uninitialized in this fresh worktree and well outside
what a real `mrbc`-only host build needs -- the same `mruby-rgss`/LVGL
final-link gap this ADR's own `Game::Rng`/`Game::Troop`/`RGSS::Tilemap`/
`RGSS::Bitmap` follow-ups already document hitting and routing around, not
a new environment problem this round introduced. Used the identical
alternate, still-rigorous fallback those rounds already established:
`g++ -std=gnu++17 -Wall -Wextra -Winfinite-recursion -fsyntax-only`
against each real, freshly regenerated `*_gen.cpp` plus its own real
`register.cxx` and the real mruby headers (`3rd/mruby/include`, the real
generated `mruby/presym/id.h` from this same round's own host `mrbc`
bootstrap build).

**Confirmed clean, re-verifying round 27's own state on the current tip**
(60 real owners today, unchanged since round 27 -- `RGSS::Bitmap` and the
`Game::Actor`/`Game::Party` `battle_support.rb` coverage round that
followed it were both documentation-only, adding zero registrations):

- 545 native names from `NATIVE_SRCS`, 39 flipped MONO-to-POLY -- exactly
  matching round 27's own recorded figures, no drift.
- The empty-method-name bug detector (`grep -c 'mrb_funcall(M,
  [a-z0-9]*, "", '`) against all three real, freshly regenerated
  `*_gen.cpp` files (`lcf_compiled_gen.cpp`/`rpg2k_compiled_gen.cpp`/
  `rgss_compiled_gen.cpp`) and against the unrestricted whole-program
  dump: **zero** everywhere.
- A from-scratch reimplementation of round 27's own exhaustive
  registration/arity/visibility cross-diff (a fresh script, not a rerun of
  a saved one, deliberately to catch anything a stale checker might have
  missed): for each of the three gems, parsed its own real, filtered
  `== compiled entry points ==` listing and cross-checked every
  `(owner, name, arity, private?)` tuple against every real
  `mrb_define_(private_)method` call actually present in its own
  `register.cxx`, resolving each call's own `RClass*` variable back to a
  real owner path through the file's own `mrb_module_get`/`mrb_class_get`/
  `mrb_class_get_under`/`mrb_module_get_under` chain (fixed-point, so a
  nested owner like `LCF::MapTree` resolves correctly through its own
  parent variable). **893 total registered methods across all three gems
  (33 + 822 + 38), zero mismatches on owner, arity, or visibility in
  either direction** -- exactly reproducing round 27's own count on the
  current, larger owner set, confirming neither `RGSS::Bitmap` nor the
  `Game::Actor`/`Game::Party` documentation round introduced any drift.
- Every currently-embedding class's real generated `struct ..._ivars`
  field list, cross-checked against every real `DATA_PTR(self)->field`
  access site in the freshly regenerated output (not just the struct
  definition): `Game::Transition` (`width`, `height`), `Game::Screen`
  (`flash_b`/`flash_g`/`flash_r`/`flash_power`/`flash_strength`/
  `flash_total`/`pan_tx`/`pan_ty`/`fade`/`fade_target`),
  `RPG2k::Scene::VehicleWorld` (`type`) -- every field in every struct is
  read/written by at least one real `GETIV`/`SETIV` site and no access
  anywhere names a field absent from its own struct. A structural note
  worth recording, not just a clean result: field *order* can never
  actually matter for correctness in this codegen scheme regardless --
  every access goes through a named C struct member
  (`((Foo_ivars*)DATA_PTR(self))->field`), never a positional/packed
  layout, so a real field-list drift could only ever manifest as a
  missing or extra field (both checked and absent here), never a
  silently-transposed one. `mrb_data_init` is called, and only called,
  for exactly these three classes' own `#initialize` bodies, matching the
  three real `MRB_SET_INSTANCE_TT` calls actually present across both
  `register.cxx` files (`screen`, `transition`, `vehicle_world`). No new
  embedding target has been added since round 27's own equivalent check,
  so this reproduces (not merely repeats) that round's own clean result
  on the unchanged set.
- `closed_world_mrblib_srcs`/`core_native_srcs` are still called from all
  three `mrbgem.rake` files via the shared `tools/bc2cpp/compiled_gems.rb`
  helpers (grepped directly, not assumed) -- no gem has reverted to a
  hand-inlined literal. Re-confirmed the one asymmetry in
  `closed_world_mrblib_srcs` itself is still harmless: it globs
  `mruby-rpg2k/mrblib/**/*.rb` (recursive, matching that gem's own real
  `game/`/`scene/` subdirectories) but `mruby-lcf/mrblib/*.rb` and
  `mruby-rgss/mrblib/*.rb` non-recursively -- checked directly rather than
  assumed still true: neither `mruby-lcf/mrblib` nor `mruby-rgss/mrblib`
  has ever grown a subdirectory of its own (`find ... -type f -name
  '*.rb'` on each shows every file directly in `mrblib/` itself), so the
  non-recursive glob is not a live gap today, only a real precondition
  worth re-checking if either gem's own source layout ever changes.
- All three real, freshly regenerated `register.cxx` files compile clean
  with `g++ -std=gnu++17 -Wall -Wextra -Winfinite-recursion -fsyntax-only`
  (with each gem's own real `OTHER_DECLS_HEADER` wired, matching its own
  `mrbgem.rake`): **zero errors, zero `-Winfinite-recursion` warnings** in
  all three, only the same pre-existing, unrelated
  `-Wunused-but-set-variable`/`-Wunused-parameter` noise this file already
  documents in many earlier rounds.
- No real cross-gem devirtualized call exists in the current output,
  re-checked directly against the freshly regenerated files (grepped
  every `MONO`/`TYPED` devirtualization comment in each gem's own
  generated `.cpp` for a target whose owner isn't that gem's own): zero
  matches in all three, same "mechanism sound, nothing to bite into yet"
  result this ADR's own dedicated cross-gem sweep already established,
  reproduced on the current, larger owner set.

**Checked directly, confirmed absent: every other Ruby method-definition
mechanism this round's own task brief named as a candidate blind spot.**
Grepped the whole real `mruby-rpg2k`/`mruby-lcf`/`mruby-rgss` mrblib tree
(not assumed from memory) for `define_method`, `define_singleton_method`,
`class_eval`, `instance_eval`, `module_eval`, `extend self`/a bare
`extend(...)` call, and `Class.new` (with or without a block): **zero
real occurrences of any of them, anywhere in the closed world.** This
codebase's own real style never reaches for any of these -- every method
this project defines is a plain `def`/`def self.x`/`class << self; def
...; end`/`attr_*`/`Struct.new`/`module_function` site, the seven shapes
this file's own prior rounds already found and (where live) fixed. Not
fully vacuous, though: the bare Ruby `alias` *keyword* (as opposed to
`Kernel#alias_method`, this file's own already-documented sixth
installation-mechanism gap) also has zero real occurrences -- confirmed
separately, since it compiles to a distinct, dedicated `OP_ALIAS` opcode
`bc2cpp.rb` has never referenced anywhere, a second, narrower gap than
`alias_method`'s own runtime-`SEND` shape that happens to have nothing to
find here today either.

**A genuinely new, previously-undocumented structural gap, found and
confirmed live -- an eighth, structurally distinct instance of the
"invisible to `build_registry`" family, but on a different axis than any
of the first seven.** Every prior instance this file documents (`attr_*`,
`Struct.new`, `SDEF`, `SCLASS`, `alias_method`, `module_function`) is
about *which mechanism* installs a method invisibly to the registry's own
`TDEF`/`DEF`-only walk. This one is about *where the installing code
lives*: `build_registry`'s `walk` lambda only ever recurses into a child
irep when a `CLASS`/`MODULE`/`SCLASS` opcode is immediately followed by a
matching `EXEC` on the same register (real Ruby's own class/module-body
opening shape) -- but when it hits `TDEF`/`SDEF`/the unfused `DEF` case,
it registers a `MethodDef` and moves on *without ever recursing into that
method's own child irep*, by design (a leaf method body is exactly what
this compiler treats as opaque, uninspected Ruby code, the whole reason
`compile_method` exists as its own separate pass). That means a real
`class << SomeObject; def foo; ...; end; end` (or a `Struct.new`/
`attr_reader`/etc.) construct written **textually inside a `def`'s own
body** -- executed each time that method runs, not once at class-load
time -- is invisible to `build_registry` in a way none of the seven
already-documented findings are: not even a synthetic (`irep: nil`)
placeholder gets registered for it, because the registry-building walk
never looks inside a leaf method's own instructions for a `CLASS`/
`MODULE`/`SCLASS` opcode at all.

**Confirmed real and live, not hypothetical**, by grepping the whole
closed world for every `class << `/`^\s*class `/`^\s*module ` occurrence
and checking each one's own real indentation/enclosing `def` directly:
every such construct in this codebase is written at ordinary class/module
top-level scope *except* two, both inside `RGSS.effect_probe`
(`mruby-rgss/mrblib/lib.rb`, a `def self.effect_probe` that drives the
real renderer to prove screen effects reach the display -- run only via
`rpg_maker_clone --rgss_effect_probe`, never during ordinary gameplay):

```ruby
def self.effect_probe
  ...
  class << Graphics
    alias_method :_probe_update, :update
    def update
      _probe_update
      $rgss_probe_mid = RGSS.frame_mean if $rgss_probe_mid.nil?
    end
  end
  Graphics.transition(4)
  class << Graphics
    alias_method :update, :_probe_update
  end
  ...
end
```

This genuinely, at runtime, redefines `Graphics.singleton#update` (twice:
once to a probing wrapper, then back) -- a real `SCLASS`+`TDEF` pair, just
reached from inside `effect_probe`'s own irep rather than from a
class/module body's. Confirmed absent from the real registry, directly:
the whole-program dump's own `:update` entry shows exactly 22 real
definitions (every compiled/interpreted `#update` this codebase already
has, `<native>` included) -- no 23rd `Graphics.singleton` entry anywhere,
confirming the registry-building walk truly never reaches this
method-body-nested `SCLASS` at all, not merely that it happens to
resolve to an already-POLY name by coincidence.

**Confirmed NOT currently exploitable, checked three independent ways
rather than assumed safe by the shape alone:** `Graphics` (and
`Graphics.singleton`) is not, and has never been, an owner in any of the
three gems' own `BC2CPP_COMPILED_GEMS[...][:owners]` lists, so
`compile_send`'s own already-established owner-not-emitted guard would
refuse to devirtualize into it even had this been registered as a real
target; `:update` is already POLY with 22 real definitions regardless (a
23rd, unregistered one changes nothing about that conclusion -- adding a
missing collision to an already-POLY name can only ever confirm POLY,
never flip a false MONO the way this exact shape did for `attr_reader`/
`Struct.new`/`SDEF`/`SCLASS`-at-class-level when the colliding name
*was* otherwise MONO); and `effect_probe` itself only ever runs under a
dedicated diagnostic CLI flag, never on any real gameplay code path. This
is the same "real, structural, checked-and-confirmed-safe-today" bucket
several of this file's own prior findings already occupy (the
`NATIVE_SRCS` `'<native>'`-owner-scope gap, the `Enumerable`
bytecode-stdlib blind spot) -- documented here as a real gap in
`build_registry`'s own model, not fixed, since fixing it (recursing into
every leaf method body looking for embedded `CLASS`/`MODULE`/`SCLASS`
constructs, a real, separate piece of work touching the core walk
structure) is not justified against zero live effect and exactly two
real, non-gameplay occurrences in the whole closed world today. Flagged
here for whoever next adds a class reopened this way -- inside a method
body, not at ordinary class/module scope -- to a compiled gem's own
owner list.

**Round 27's `module_function` fix, checked against devirtualization and
embedding specifically, no interaction bug found.** Traced every consumer
of a `MethodDef` with `irep: nil` (the shape `module_function`'s own fix
installs, under the `"Owner.singleton"` pseudo-owner `SDEF`/`SCLASS`
already use) through the actual code, not just by analogy to the other
synthetic-`MethodDef` fixes: `monomorphic_target` (`return nil unless
defs.first.irep`), `IvarLayout.analyze`'s own `methods_of`/`def_of_irep`
construction (`if d.irep` on both), `ArgTypes.analyze` (`next unless
defs.first.irep`), and `report_annotation_candidates` (`next unless
d.irep`) all already guard on exactly this field, the same way they
already had to for `attr_reader`/`Struct.new`/`SDEF`/`SCLASS`'s own
`irep: nil` entries well before `module_function` existed -- so
`module_function`'s fix needed no new guard anywhere in this file, and
introduces none. `natively_exposed?` (`drop_unsafe_embeddings`'s own
collision check) can never spuriously match a `module_function`-installed
entry either: it compares `d.owner == owner` against the real embedding
class's own bare name, and every `module_function` entry's owner carries
the `.singleton` suffix -- a string no real Ruby class name can ever
equal (`.` is not a legal character in a constant path), so this
comparison is unconditionally false for every such entry, confirmed by
reading the one-line check directly rather than assumed from the
`SDEF`/`SCLASS` precedent alone. Re-ran the real whole-program diagnostic
specifically checking whether any embedding-eligible class today also
happens to be a module with a same-named `module_function` entry (the one
shape that could theoretically probe this interaction for real, since
`module_function` only ever fires on a `module`, never a `class`, and
none of the three currently-embedding classes -- `Game::Transition`/
`Game::Screen`/`RPG2k::Scene::VehicleWorld` -- are modules at all,
confirmed directly against their own real `CLASS` vs. `MODULE` opcodes in
the disassembly): none is, so this interaction has zero live surface
today on top of having no code-level gap to begin with.

**Other angles checked this round, no live bug found:**

- Re-derived (not re-read) the numeric-overflow acceptance round 27
  already recorded for `ADD`/`SUB`/`MUL`/`ADDILV`/`SUBILV`'s shared
  fixnum-fastpath codegen (a raw C `+`/`-`/`*` with no overflow check,
  against the real interpreter's own bignum-promoting `OP_MATH`/
  `OP_MATHI`/`OP_MATHILV`) by reading `3rd/mruby/src/vm.c` directly in
  this round's own freshly built checkout -- still accurate, still the
  same accepted, explicitly-documented tradeoff, not re-litigated as new.
- Checked `mrb_hash_get`/`mrb_ary_ref` (the real C APIs `GETIDX`/
  `GETIDX0`/`AREF`'s own codegen already calls) against
  `3rd/mruby/src/hash.c` directly for whether they honor a `Hash.new
  (default)`/`Hash.new { |h,k| ... }` default value or block the way
  `Hash#[]` itself does, rather than assumed equivalent from the API
  name alone: confirmed -- `mrb_hash_get` *is* `Hash#[]`'s own real
  underlying implementation (`hash_get`, `3rd/mruby/src/hash.c`, calls it
  directly), so a compiled `GETIDX`/`GETIDX0` read against a
  Hash-with-a-default is already exactly as correct as the interpreter's
  own `[]` call, no divergence to find.
- Checked `compile_cmp`'s own `EQ` fixnum-fastpath-else-`mrb_funcall`
  simplification (already flagged, several rounds up, as skipping the
  real VM's own object-identity/Symbol-specific short-circuits before
  falling back) for whether it could ever produce a genuinely different
  *result*, not just a slower path, for a same-object or Symbol
  comparison: it cannot -- `Kernel#==`'s own default implementation
  (identity) and `Symbol#==`'s own native implementation both already
  give the identical boolean answer `mrb_funcall` would obtain either
  way, confirmed by reading both implementations directly rather than
  re-trusting the existing comment's own claim unchecked.
- Re-confirmed keyword-argument-default evaluation order and
  exception/`rescue` semantics remain structurally impossible to diverge
  under this compiler, not just unlikely: `pure_mandatory_arity?` refuses
  to compile *any* method with a nonzero optional/keyword/rest/block field
  before a single instruction of its own body is ever inspected, and no
  `compile_insn` case exists for `RESCUE`/`RAISEIF`/`EXCEPT` at all (an
  unconditional `#error`, the generic unhandled-opcode fallback) -- so
  there is no default-value expression and no `rescue` clause this
  compiler ever actually translates into C++ for either class of
  divergence to hide in.

**Full-sweep re-check:** all sixty now-shipped targets' own entry-point
counts, re-derived from this round's own fresh registration cross-diff
above rather than copied from any prior round's own listing, match
exactly; nothing moved, no method gained or lost registration, no
struct's own embedded field set changed. Zero `bc2cpp.rb`/`compiled_gems.rb`/
`register.cxx` changes were made this round -- every finding above is
either a clean re-confirmation of round 27's own state on the (unchanged
since round 27) 60-owner set, or a real, checked-and-confirmed-not-live
structural gap (the method-body-nested `class << Graphics` finding) in
the same documented-but-not-fixed bucket several of this file's own prior
rounds already use for a genuine gap with zero live effect and no
currently-compelling reason to fix. No changelog fragment accompanies
this round for the same reason: nothing shipped changed behavior.
