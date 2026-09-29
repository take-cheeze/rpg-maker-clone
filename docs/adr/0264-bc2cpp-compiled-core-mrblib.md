# 0264. Compiled mruby core mrblib

Date: 2026-09-30

## Status

Accepted

## Context

bc2cpp compiles the engine's own Ruby (`mruby-rpg2k`, `mruby-lcf`, `mruby-rgss`)
and resolves calls against a whole-program registry of those definitions. mruby's
own Ruby (`3rd/mruby/mrblib/*.rb`, each core gem's mrblib, and the mrblib of the
three external gems) was never part of that:

- `closed_world_mrblib_srcs` named the three engine gems only, so a method
  defined by core Ruby (`Numeric#positive?`, `Comparable#between?`,
  `Hash#compact`, `Enumerable#min`, ...) was not a registry definition. A call
  to it stayed `bc2cpp_send` even with a proven receiver.
- `foreign_mrblib_srcs` and `bc2cpp_closed_world_outside_srcs` scanned those
  files as text only: constant names (INTEGER_CONSTANT_PROOF), method names
  (FIXNUM_RETURN_PROOF, ADR 0203's dynamic-name set) and, in a closed world,
  the outside names and class touches (ADR 0210, 0256). They were proof
  *inputs*, never compiled.
- `core_native_srcs` and `external_gem_native_srcs` give the native method
  *names* (`<native>` placeholders in the registry). Nothing said which class
  registers one.

The baseline (wio closed world, `scripts/bc2cpp_coverage_report.rb`) had 467
generic POLY sites; the largest unresolved names that are core Ruby were `min`
(32), `sort` (9), `negative?`/`positive?` (18), `read`/`open`, `uniq` and
`Hash#compact`.

Compiling core Ruby is not a matter of listing more files. Findings that shape
the design:

1. **Name-keyed fast paths model mruby's own methods.** FIXNUM_COMPARE,
   FIXNUM_BINARY, `LITERAL ===`, INTEGER_UNARY, the ELEM/ARRAY return proofs and
   the inline `each`/`collect` loops all require that the registry holds only the
   native definition of a name (`native_only_mono?`, `eqq_literal_devirt_safe?`,
   ...). Making every core definition a registry definition turned 812
   FIXNUM_COMPARE, 365 LITERAL, 137 FIXNUM_BINARY and 97 INTEGER_UNARY sites into
   dispatch and lost 7 ivar-class hints. The registry cannot simply be complete.
2. **A compiled frame cannot sit under a `Fiber.yield`.** mruby raises FiberError
   for a yield through a C frame. The RGSS script host yields from
   `Graphics.update` inside blocks of `loop`, `times`, `each`; Enumerator#next
   yields from inside the iteration. A compiled `Array#each`, `Kernel#loop` or
   `Integer#times` breaks both. The engine's own methods avoid this with a
   reachability analysis over the engine's Fiber bodies; user blocks passed to
   core iterators cannot be analysed.
3. **Core methods are replaced late.** A compiled body registered by a gem's init
   replaces whatever is defined at that moment, so it must follow every gem whose
   mrblib defines the same (owner, name) and must not replace a definition a
   later gem makes.
4. **Shared owners.** `Array` and `StringIO` are owners of both mruby-rgss /
   mruby-lcf (engine) and core Ruby; a translation unit may emit a symbol once.
5. **Latent bugs surface.** Running core code through the differential check found
   a segfault in the existing generated `==` arm for Integer receivers
   (`mrb_obj_ptr` on an immediate) and, through the mrbc parser, an ALIAS text
   dump that the binary loader check compared against (see Decision).

## Decision

### What is compiled

`mruby-core-compiled` (new, `BC2CPP_COMPILED_GEMS`) compiles core Ruby with the
same pipeline and registers it through the generated
`bc2cpp_register_owner_methods`, exactly as `WIRED_EMBEDDINGS` owners already are
(no hand-kept register list). Inputs: `3rd/mruby/mrblib/*.rb` plus the mrblib of
`BC2CPP_CORE_MRBLIB_GEMS` (array-ext, hash-ext, enum-ext, numeric-ext, range-ext,
string-ext, sprintf, struct, io, dir, enumerator) and
`BC2CPP_EXTERNAL_MRBLIB_GEMS` (mruby-stringio, mruby-onig-regexp; mruby-marshal has
no mrblib), in the interpreter's load order, filtered to the gems the build really
has (`bc2cpp_closed_world_srcs`, from `spec.build.gems`). Two files stay outside
(`BC2CPP_CORE_MRBLIB_EXCLUDED`): mruby-io's `kernel.rb` (`(...)` forwarding, modelled
elsewhere by IO_PUTS_MODEL; mrbc's multi-file parse keeps that state) and
`10error.rb` (accessors only).

A core definition compiles unless `CoreMethods` (`tools/bc2cpp/core_methods.rb`)
keeps it bytecode:

- it **takes, builds, yields to or forwards a block** (`BLKPUSH`, `BLOCK`,
  `LAMBDA`, `SENDB`, `SSENDB`, or a block parameter), or names the Fiber class,
  or comes from mruby-enumerator (finding 2);
- a later definition of the same owner and name replaces it (`shadowed`; dropped
  from the registry, so the later engine definition is the live one);
- a conditional forward jump can skip its `def` (none today);
- it is listed in `tools/bc2cpp/core_refused.txt`.

Of the 220 core-source methods in the wio gem set, 58 are eligible and 56
compile; 132 touch a block, 25 are mruby-enumerator's, 5 are shadowed. The
desktop set (with mruby-dir and Onigmo) has 71 eligible, 69 compiled.

### Which definitions are registry definitions

Only a core method whose **name no native method shares** (and that is not a
fast-path operator, `CoreMethods::OPERATOR_NAMES`) is a registry definition, so a
dispatch target: `positive?`, `negative?`, `nonzero?`, `integer?`, `allbits?`,
`anybits?`, `nobits?`, `ceildiv`, `between?`, `overlap?`, ... (22 methods). The
other 34 (`Comparable#<`, `Numeric#-@`, `Hash#compact`, `String#%`, ...) are compiled
and registered but stay outside the registry (`CodeGen.core_hidden_defs`, emitted
through `@owner_of`): they serve the interpreter's dynamic sends and add no
candidate, so finding 1's name-keyed proofs see exactly the world they always
did. Engine output with the core gem left out differs from before only in the
`positive?`/`negative?` diagnostics, the Integer arm fix below and two
registration lines.

Inside a core method's body only core definitions and the native placeholders are
static call targets (`core_targets`), and the closed world is switched off for the
body (a core method is not part of the engine's closed world). The closed-world
analysis itself is unchanged: core files are still outside sources for it, its
ireps/walk exclude them, and `symbol_installed_names` ignores core aliases.

### Emission and registration

- `emit_unit_allows?`: the core gem's run (owners all in `BC2CPP_CORE_OWNERS`)
  emits core-source definitions; a run with any other owner (an engine gem, or the
  aggregate of all gems) emits the rest. `Array#include?` (mruby-rgss) stays with
  `mruby-rgss-compiled`, `StringIO#ungetbyte` with `mruby-lcf-compiled`.
- `BC2CPP_CORE_OWNERS` is exactly the set of classes core sources define methods on
  (`Object` excluded: mruby-rpg2k's `main.rb` defines engine methods there). The
  check fails on a new or stale owner.
- The gem depends on every core gem it replaces and on mruby-lcf/rgss/rpg2k.
  build_config.rb's gem dispatch initialises a gem that depends on a maker
  directly right after that maker, so the compiled core is registered for an
  RPG2000/2003 run only; the XP/VX/Wolf/MV makers keep the interpreted core (their
  scripts are the Fiber case of finding 2, which the block filter already covers
  but which has not been validated with compiled core methods live). The compiled
  bodies are always linked, so compiled engine code may still call them directly.
- **Hot-only builds (wio, psp, maix; ADR 0214) get no core Ruby in the world**
  (`bc2cpp_closed_world_srcs` returns none for them) and hidden definitions are
  excluded like any unlisted method: the gem is an empty translation unit and the
  generated engine code for those targets differs from before by the Integer arm
  fix only.

### Fixes found while testing (engine output changes)

- `==` (and any native expression) on an `Integer` receiver tested
  `mrb_obj_ptr(v)->c == M->integer_class`, reading through an immediate: a
  segfault for `5 == nil`-shaped compares that reach the arm. `Integer` joins
  `Float` and `Symbol` in `IMMEDIATE_NATIVE_CLASSES` (616 arms in the wio
  aggregate, 121 in the hot-only build).
- `scripts/bc2cpp_binary_loader_check.rb` compared the loader with `mrbc -v` text,
  whose `ALIAS :succ next` reads `:succ succ` (codedump.c prints two short-symbol
  `mrb_sym_dump` results from one shared buffer; the bytes agree with vm.c). Only
  the first name of such a line is compared.
- `InsnDecoder` scrubs a binary pool string (mruby-wolf's `data.rb`).

### Verification

- `scripts/bc2cpp_core_mrblib_check.rb` (bc2cpp-checks fast shard): owner
  completeness; each core method emitted by exactly one gem; no compiled core
  method touches a block, Fiber or mruby-enumerator; no open-world gem
  (rpgxp/rpgvx/wolf/mvjs) redefines a compiled method or, for registry
  definitions, its name; a hot-only world names no core file; no stale refusal;
  and a differential run (3,821 cases) of every compiled body against the
  interpreter through registered entry points and through direct calls from
  compiled callers: 0, -0.0, NaN, infinities, nil, non-numeric operands, the
  largest fixnum power, empty/endless/beginless ranges, wrong counts and types.
  The only tolerated difference: a registered aspec makes the VM raise
  `expected 1+`/`1..2` where OP_ENTER's own check of the bytecode says
  `expected 1` (vm.c `argnum_error`); class and counts agree.
- `scripts/bc2cpp_core_mrbtest.rb` (own shard): mruby's own `rake test` on a
  full-core host build, interpreted and with the compiled core registered over
  it: 1846 assertions, 1845 OK, 0 KO, 0 crash, identically.
- Semantic diff of the generated engine output against the previous commit
  (digit-masked line multisets, whole file): the hot-only build differs by 121
  Integer-arm lines; the wio aggregate by 616 of them plus the 22
  `positive?`/`negative?`/StringIO lines above.

## Consequences

- Coverage report (wio closed world): generic POLY sites 467 -> 449 in engine
  methods (`positive?` 7 and `negative?` 11 resolve to `Numeric#...`
  direct calls); the 65 more that the report now counts are inside the 56 newly
  compiled core methods and are reported separately ("in compiled mruby-core
  mrblib methods"). Compiled entry points 2866 -> 2922. The excluded-definition reason
  `native_or_uncompiled` moves 1033 -> 1034 (the engine registry keeps its native
  names; the one more is inside a core method).
- Size: `mruby-core-compiled` adds 56 methods, 11.8k lines of C++, 73 KB of
  x86-64 text (-O3, desktop build) to a build that compiles core Ruby; 0 bytes to
  wio/psp/maix (hot-only worlds hold no core Ruby).
- Not done, and why:
  - `min`, `sort`, `uniq`, `compact` (Array), `first`, `inspect`, `read`/`open`
    resolve nothing: `Enumerable#min`, `Array#sort`, `uniq`, `File.open` take or
    yield to a block (finding 2), and `Hash#compact`, `Range#first`, `IO.read` share
    a name with a native method, so making them registry definitions would switch
    off the proofs of finding 1. Both need something new: a Fiber-safe way to run
    a compiled iterator (or a closed-world-only opt-in), and per-class native
    knowledge (which class registers which native) so a native name does not
    poison every class.
  - The `first`/`last` native expressions for `Range` (`mrb_range_beg`) predate
    mruby-range-ext, whose `Range#first` raises for a beginless range; still
    unsound, still unchanged (per-class native knowledge would fix it too).
  - The compiled core is not registered for the XP/VX/Wolf/MV makers.
  - Nothing runs a 32-bit `mrb_int` build. The compiled set uses fixnum
    arithmetic through the existing overflow-checked paths and no bigint
    literal compiles (`LOADL` of a bigint is `#error`, so those methods stay
    bytecode); reasoned by hand, not exercised.
- A registered compiled method is a C function to reflection, like every compiled
  engine method: `Method#source_location` is `nil` and `Method#arity`/`#parameters`
  read `-1`/`[]` instead of the bytecode's (`Array#dig`: `-2`,
  `[[:req, :idx], [:rest, :args]]`). Nothing in the RPG2000/2003 run reflects on
  core methods.
