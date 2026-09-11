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
