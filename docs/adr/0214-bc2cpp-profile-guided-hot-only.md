# 0214. bc2cpp compiles only profiled hot methods on flash-limited builds

Date: 2026-09-23

## Status

Accepted

## Context

bc2cpp's generated C++ is about four times the size of the bytecode it
replaces. At `-Os` the RPG2k compiled gem is 4.75 MB of text over 2,190 entry
points, with a long tail. A callgrind run of a normal session executes only a
small part of it. psp, wio and maix (build_config.rb's `single_format_only`)
are limited by flash, not speed, so most of those bytes buy nothing.

Until now the only way to select code was by owner: `ONLY_OWNERS` and
`OTHER_OWNERS` choose whole classes. A class's cold methods cost as much
flash as its hot ones.

## Decision

### Method-level exclusion

`BC2CPP_HOT_METHODS=<file>` names a list of methods, one `Owner#name` or
`Owner.singleton#name` per line, spelled the way bc2cpp's own diagnostics
spell them (`tools/bc2cpp/hot_methods.rb`). Every bytecode method the list
does not name is *excluded*. That includes methods written after the profile
was taken; they stay interpreted, which is always correct.

An excluded method is treated exactly like a method whose body bc2cpp cannot
compile, the long-standing `SKIP_UNSUPPORTED=1` case:

- `CodeGen#compiles_clean?` answers false for it before compiling anything.
  Every path that calls a target's `_impl` directly already gates on that
  predicate: MONO, POLY_SMALL_N, TYPED, LEXICAL_SELF, `super`, direct `.new`
  construction and `&:sym` chains. So every compiled caller reaches an
  excluded method through ordinary dispatch (`bc2cpp_send`). A guard chain
  simply leaves the excluded candidate out and keeps its by-name fallback.
- `compile_all` never compiles it. It gets no `_impl`, no entry wrapper, no
  forward declaration and no line in the `*_decls.h` another compiled gem
  includes.
- `drop_unsafe_embeddings` also goes through `compiles_clean?`. An ivar that an
  excluded method touches is not embedded, because the interpreted method
  would read the iv_tbl. A class whose `#initialize` is excluded embeds
  nothing. The ATTR_STRUCT_DEVIRT accessors and MONO_EMBED_GUARDs that depend
  on the embedding go with it.
- The exclusion is a class-level `CodeGen.hot_only_excluded` set. The driver
  sets it before the first CodeGen, so every probing CodeGen sees it too:
  FIXNUM_RETURN_PROOF, ARRAY_RETURN_PROOF, the IvarLayout/ClassLayout
  stratification and the ENTRY_ARG alternation all run against the real
  exclusion. Those proofs reason about bytecode, and an excluded body is the
  same bytecode running on the VM. Wherever a proof depended on a compiled
  body, through `compiles_clean?` or an embedded field, it now sees that the
  body is not compiled.
- Each compiled gem's run reads the same list and the same whole-program
  registry, so all three agree on which `_impl`s exist. build_config.rb's
  `bc2cpp_hot_only_build?` refuses a build whose compiled gems disagree.
- CLOSED_WORLD (ADR 0210) needs nothing new. Its proofs are about who defines
  a name, and an excluded method still defines it. A chain that lost an
  excluded candidate no longer lists every definer, so it keeps its dispatch
  (`unlisted_class`).

Three outputs change only when something is excluded. With an empty
exclusion the generated code and the decls header are byte-identical to
today's:

1. **Hand-written registrations.** Each gem's `register.cxx` names entry
   wrappers in plain `mrb_define_method(M, cls, "x", Entry, aspec)` calls.
   The generated file declares every entry of the run's owners that did not
   compile as a constant of an empty type, `bc2cpp_hot_only_excluded`. It
   also adds a static overload of `mrb_define_method`,
   `mrb_define_private_method` and `mrb_define_class_method` that takes that
   type and does nothing. The hand-written line compiles and registers
   nothing, so the bytecode `def` stays the method. Overload resolution
   matches the exact type, so a real `mrb_func_t` can never select the
   no-op, and any other use of an excluded name is a compile error. The same
   covers the synthesized accessors of an embedding that the exclusion
   dropped (the native attr_reader is then correct again). It also covers a
   *listed* method that failed to compile: a keyword call or `super` into an
   excluded method has no dynamic fallback, so the caller comes out `#error`.
   No script that parses or prunes `register.cxx` changes.
2. **Static-dispatch unregistration (ADR 0203).** That proof assumes the
   full compile: every caller of an unregistered name is compiled code that
   calls `_impl`. An excluded caller runs as bytecode and looks the name up,
   and so does a guard chain that lost a candidate. For an embedded owner
   the bytecode fallback would read an iv_tbl that its compiled siblings
   never write. So whenever something is excluded, `emit_owner_registrations`
   registers every compiled `STATIC_DISPATCH_UNREGISTERED` entry again. This
   restores the pre-0203 rule that a compiled method is a registered method,
   which needs no proof.
3. **wio/host bytecode strip (ADR 0144).** `wio_strip_bc2cpp_stubs` runs its
   probe with the build's list. An excluded method is not a compiled entry,
   so its bytecode `def`, the only implementation it has, is never stripped.
   In a hot-only build `WioRegisteredMethods.strippable?` also drops the
   ADR 0203 exemption that let an unregistered name strip, so only a real
   registration counts.

### Scope

build_config.rb enables `enable_bc2cpp_hot_only` together with
`enable_bc2cpp_closed_world` for psp, wio and maix. Desktop, wasm and android
compile everything. `BC2CPP_HOT_ONLY=1` makes any build hot-only (the
desktop test configuration) and `BC2CPP_HOT_ONLY=0` turns it off. The list
is a prerequisite of each compiled gem's codegen task and of the CMake rake
step. Changing the environment variable does not trigger a rebuild, so use a
separate build directory.

### The profile

`scripts/bc2cpp_hot_profile.rb` regenerates `tools/bc2cpp/hot_methods.txt`
(procedure in docs/profiling.md). It works in two steps.

`record` runs fixed-frame scenarios under callgrind on a full-compile desktop
build. Each scenario counts `RPG2k#main_loop` calls driven through
`--script`, so the work does not depend on how slowly callgrind runs. On
Nepheshel the scenarios are:

- map idle (1,800 frames);
- `--rpg2k_battle_play` against troops 1 and 6;
- walking plus every main-menu sub-screen;
- save and load: Marshal, `State#to_lsd`, then `State.from_lsd` through
  `continue_game`;
- a battle animation.

Each extra game (kk1.12, histoire, yumenikki) gets a boot and a walk/menu
run.

`select` sums self Ir per method and takes the smallest set that covers the
threshold of all compiled-code Ir. The build carries `-g`, so Ir is
attributed by source line of the generated `*_gen.cpp`. That stays correct
when an optimizing build inlines an `_impl` into its caller. Blocks and the `block_fallback`, `rescue_try` and nested
helpers count for the method that owns them. Two closures follow:

- **The `#initialize` of each class with a hot method.** Excluding a
  once-per-object constructor un-embeds every ivar of the class. That
  happened in the first measurement: the embedding classes fell from 34 to 1.
- **Every keyword-call or `super` target of a listed method, to a fixpoint.**
  bc2cpp has no dynamic form for either, so without its target the caller
  itself stops compiling. That hit `RPG2k::Scene::Map#update` through
  `step_events(allow_trigger:)`.

bc2cpp prints `== hot-only: listed but not compiled ==`, which is empty for
the checked-in list.

## Consequences

Measured on the checked-in profile. There are 12 callgrind profiles, and
1,245 of 2,291 compiled methods executed at all.

| threshold | methods (by Ir + init + required) | rpg2k `-Os` | lcf | rgss | total | map | battle 6 | walk + menus | not profiled |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| full compile | 2,291 | 4,750,480 | 62,561 | 186,691 | 4,999,732 | — | — | — | — |
| 98% | 179 + 17 + 6 = 202 | 591,318 | 29,867 | 14,014 | 635,199 | +3.3% | +5.0% | +4.6% | +8.1% |
| **99%** (checked in) | 220 + 22 + 6 = 248 | 654,583 | 34,942 | 14,026 | **703,551** | +1.6% | +3.2% | +3.1% | +7.0% |
| 99.5% | 267 + 22 + 6 = 295 | 737,871 | 38,321 | 20,196 | 796,388 | +1.3% | +2.7% | +2.6% | +6.6% |

The speed columns are engine-binary Ir deltas against the full compile, as in
the table further down. Going from 99% to 99.5% costs 93 KB for about half a
point. Going from 99% to 98% saves 68 KB for one to two points.

These are x86-64 g++ `-Os` text figures, measured by compiling each gem's
`register.cxx` with the build's own flags. On wio, which also runs
closed-world, rpg2k goes from 4,643,149 to 644,051. The flash the bytecode
reclaims shrinks accordingly. The wio mrblib of mruby-rpg2k, after its wio
file exclusions and the stub strip, grows from 42,198 to 410,248 bytes of
`mrbc` output (+368,050), because the excluded methods keep their `def`s.
lcf and rgss bytecode is never stripped, so it does not change. Net wio
flash estimate: 4,892,401 − 693,019 (compiled text, closed world) − 368,050
(bytecode kept) = **−3.83 MB**.

Speed is callgrind Ir of the engine binary (SDL and libc are excluded: the
SDL blit under xvfb swings the process total by up to 45% from run to run), full compile
against hot-only, on the default desktop build:

| scenario | full | hot-only 99% | delta |
| --- | ---: | ---: | ---: |
| map idle | 8.579 G | 8.715 G | +1.6% |
| battle troop 1 | 11.475 G | 11.745 G | +2.4% |
| battle troop 6 | 14.981 G | 15.455 G | +3.2% |
| walk + menus | 10.882 G | 11.215 G | +3.1% |
| save/load | 25.385 G | 25.532 G | +0.6% |
| histoire walk | 11.845 G | 12.213 G | +3.1% |
| yumenikki walk | 12.665 G | 12.739 G | +0.6% |
| **not profiled**: Nepheshel map 10, walk + menus | 18.336 G | 19.618 G | +7.0% |

The profiled scenarios stay within about 3%. The one scenario kept out of
the profile costs 7%. That is the price of the profile's coverage: code no
scenario reached runs interpreted. An earlier 9-profile list was checked
against histoire before histoire joined the profile. It cost 10% there,
mostly in `Game::Interpreter#do_end_loop`, which Nepheshel never ran. The
threshold and the scenario list are therefore the knobs, and a new game
genre in the profile helps more than a higher threshold.

The desktop mruby gems build without `-O` (`enable_debug`, then `-O0` is
removed), so these Ir ratios understate what a `-Os` flash build would lose
per interpreted call. Treat them as a lower bound.

Other consequences:

- Registering the static-dispatch-only entries again costs a little flash. It
  is part of the hot-only figures above.
- `Game::State#to_lsd`/`.from_lsd` (98.6 and 92.6 KB at `-Os`, the two
  largest functions) are cold: two saves and one load in the save/load scenario, under 0.01% of
  compiled Ir each. So are
  the other large one-off methods (battle skill resolution, `State.load`,
  `Message.scan`, shop drawing).
- A full-compile desktop run of kk1.12 crashes at New Game with `TypeError:
  bc2cpp: expected Array receiver for inlined #each`. The cause is
  `RPG2k#start_new_game`'s rescue path, where a register that holds the
  rescued exception reaches an inlined `@scenes.each`. This is a bug in the
  existing compiler, and the hot-only and interpreted builds do not have it:
  they log "Failed to start new game" as the interpreter does. It is not
  fixed here.
- `scripts/bc2cpp_hot_only_check.rb` (in the CI `bc2cpp` job) covers the
  mechanism. It runs on a fixture world and against the real mruby core, and
  checks that the checked-in list names only existing methods.
