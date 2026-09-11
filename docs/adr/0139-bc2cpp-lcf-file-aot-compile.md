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
`#open_map_viewer` (a `rescue StandardError` clause). Neither class's
`#initialize` compiles, so neither gets any ivar embedded.

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
plainly" honesty this ADR's own every prior round already holds to.
