# 0214. bc2cpp compiles only profiled hot methods on flash-limited builds

Date: 2026-09-23

## Status

Accepted

## Context

bc2cpp's generated C++ is about four times the size of the bytecode it
replaces. At `-Os` the RPG2k compiled gem is 3.91 MB of text over 2,344 entry
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
   registration counts. A list also changes which names strip, so
   `strip_wio_bc2cpp_stubs.rb` now also drops a stripped name that ends a
   mixed `public :kept, :stripped` list. Before the fix, it shrank the list
   only up to the last kept name. The 99.7% list hit this: it strips
   `RPG2k::Scene::Map#try_open_debug_menu`, and that build then failed to
   load mrblib with a `NameError`. With the fix, it boots and passes the
   same correctness runs as the other builds.

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
when an optimizing build inlines an `_impl` into its caller. Blocks and the
`block_fallback`, `rescue_try` and nested helpers count for the method that
owns them. Two closures follow:

- **The `#initialize` of each class with a hot method.** Excluding a
  once-per-object constructor un-embeds every ivar of the class. That
  happened in the first measurement: the embedding classes fell from 34 to 1.
  A record class whose only bytecode method is `#initialize` (ADR 0215's
  `MapEventState` and friends) is used through its synthesized struct
  accessors instead. The Ir of those accessors counts for that
  `#initialize`, since the accessors exist only while it compiles.
- **Every keyword-call or `super` target of a listed method, to a fixpoint.**
  bc2cpp has no dynamic form for either, so without its target the caller
  itself stops compiling. That hit `RPG2k::Scene::Map#update` through
  `step_events(allow_trigger:)`.

bc2cpp prints `== hot-only: listed but not compiled ==`, which is empty for
the checked-in list.

## Consequences

These figures were measured on master after ADR 0215 (the rpg2k Structs became
plain classes), ADR 0216 (outlined getidx) and #1911 (LCF `[]` access without
`method_missing`). Across 12 callgrind profiles, 1,259 of the 2,307 compiled
methods executed at all.

The checked-in list uses the **98%** threshold. It is the cheapest threshold
measured at which every profiled scenario stays within the roughly +3%
engine-Ir budget; its worst case is +1.9%.

| threshold | methods (by Ir + init + required) | rpg2k `-Os` | lcf | rgss | total | wio closed world | wio bytecode kept | net wio flash |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| full compile | 2,307 | 3,906,508 | 51,100 | 167,909 | 4,125,517 | 4,017,972 | 0 | 0 |
| **98%** (checked in) | 189 + 20 + 6 = 215 | 525,115 | 24,624 | 10,934 | **560,673** | 551,144 | 375,483 | **−3.09 MB** |
| 99% | 232 + 23 + 6 = 261 | 588,272 | 28,901 | 10,964 | 628,137 | 617,081 | 366,652 | −3.03 MB |
| 99.5% | 282 + 21 + 6 = 309 | 696,868 | 31,019 | 15,843 | 743,730 | 732,459 | 355,795 | −2.93 MB |
| 99.7% | 351 | 858,369 | 33,660 | 20,174 | 912,203 | 898,897 | 345,335 | −2.77 MB |

Sizes are x86-64 g++ `-Os` text in bytes, measured by compiling each gem's
`register.cxx` with the build's own flags. "wio closed world" is the same
total under CLOSED_WORLD (ADR 0210), as wio builds it. "wio bytecode kept" is
the growth of mruby-rpg2k's wio mrblib `mrbc` output after the file
exclusions and the stub strip: 46,060 bytes in the full compile against
421,543 at 98%. The excluded methods keep their `def`s. lcf and rgss bytecode
is never stripped, so it does not change. Net wio flash is the closed-world
text saved minus the bytecode kept.

Speed is callgrind Ir of the engine binary, full compile against hot-only, on
the default desktop build. SDL and libc are excluded: the SDL blit under xvfb
swings the process total by up to 45% from run to run.

| scenario | full | 98% | 99% | 99.5% |
| --- | ---: | ---: | ---: | ---: |
| map idle | 8.679 G | +0.2% | +0.5% | −0.8% |
| battle troop 1 | 11.686 G | +0.4% | +0.5% | −0.7% |
| battle troop 6 | 15.253 G | +1.3% | +1.0% | −0.2% |
| walk + menus | 11.025 G | +0.7% | +0.6% | −0.4% |
| save/load | 25.481 G | +0.1% | +0.2% | −0.4% |
| battle animation | 9.432 G | −1.1% | −0.4% | −1.5% |
| histoire walk | 12.060 G | +1.9% | +1.3% | −0.1% |
| yumenikki walk | 12.379 G | +1.2% | +1.0% | −0.1% |
| **not profiled**: Nepheshel map 10, walk + menus | 18.296 G | −1.8% | −2.1% | −2.6% |

A negative delta means the hot-only binary executed fewer engine
instructions than the full compile for the same frames. This was not traced
to a cause. The kk1.12 walk is left out of the table because both builds end
it the same way: New Game fails in the game's own script, as it does under
the interpreter, and the driver's menu keys then reach Shutdown. The
99.7% build was not timed, because 99.5% already cost nothing measurable.
Going from 98% to 99% costs 67 KB of text for at most 0.6 points. Going
from 99% to 99.5% costs 116 KB.

The threshold and the scenario list are the knobs. An earlier list tried on
histoire before histoire joined the profile cost 10%, mostly in
`Game::Interpreter#do_end_loop`, which Nepheshel never ran. Adding a new game
genre to the profile helps more than raising the threshold.

The desktop mruby gems build without `-O` (`enable_debug`, then `-O0` is
removed), so these Ir ratios understate what a `-Os` flash build would lose
per interpreted call. Treat them as a lower bound.

Other consequences:

- The embedding classes go from 50 in the full compile to 12 at 98%. The
  kept ones include the ADR 0215 record classes the profile reaches:
  `RPG2k::Scene::Map::MapEventState` (its synthesized accessors run per event
  per frame, and their Ir counts for its `#initialize`),
  `Game::CommonEvent::CommonEventRecord` and
  `Game::Interpreter::KeyInputAccepted`. Cold ones such as `MessageState`
  stay in the iv_tbl and run as bytecode.
- Registering the static-dispatch-only entries again costs a little flash.
  It is part of the hot-only figures above.
- `Game::State#to_lsd`/`.from_lsd`, the two largest functions, are cold: two
  saves and one load in the save/load scenario, under 0.01% of compiled Ir
  each. So are the other large one-off methods (battle skill resolution,
  `State.load`, `Message.scan`, `MoveRoute#execute`).
- Two existing compiler bugs that earlier profiles ran into are fixed on
  master. #1911 fixed the `Game::Picture#zoom` direct call, which made the
  full compile skip battle-animation cells. #1909 fixed the kk1.12 New Game
  crash in `RPG2k#start_new_game`'s rescue path.
- `scripts/bc2cpp_hot_only_check.rb` (in the CI `bc2cpp` job) covers the
  mechanism. It runs on a fixture world and against the real mruby core, and
  checks that the checked-in list names only existing methods.
