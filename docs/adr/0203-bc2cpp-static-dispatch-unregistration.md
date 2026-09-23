# 203. Dropping mrb_define_method for statically-dispatched-only methods

Date: 2026-09-22

## Status

Accepted

## Context

Every bc2cpp-compiled method is two C++ functions: `Owner_name_impl`, the
translated body a devirtualized call site calls directly, and a small
`Owner_name(mrb_state*, mrb_value)` wrapper that unpacks arguments with
`mrb_get_args` and forwards. The wrapper exists for one reason -- to be
passed to `mrb_define_method` so mruby's own dynamic method-table lookup can
find the compiled method. In the real linked `wio_rgss_boot` map those
wrappers are 2,693 symbols, 308,328 bytes of `.text` plus 19,928 bytes of
unwind tables (docs/adr/0193's measurement tree, `register.o`), before
counting each `mrb_define_method` call site and its name string.
`-Wl,--gc-sections` can never drop one on its own: the registration call takes
its address, which the linker must honour whether or not anything ever looks
the name up.

docs/adr/0198 rejected removing a registration on the grounds that "every call
site to this MONO method was devirtualized" is a per-call-site property no
pass tracked, and that interpreted callers still dispatch dynamically -- with a
real counterexample (`LCF::EventCommand#code`/`#indent`). That rejection
stands for the question it asked. This ADR asks a different, strictly
stronger one that does not need per-call-site devirtualization facts at all.

## Decision

Drop the registration of a compiled method when **no runtime method-table
lookup of its name can ever happen, from anywhere** -- so every real caller is
already a direct `_impl` call in generated C++, and the wrapper is dead. The
proof is `tools/bc2cpp/static_dispatch_registrations.rb`, name-level and
dynamic-by-default. A name counts as possibly looked up if it appears in any
of:

1. **Bytecode that can run.** A method body -- compiled or not -- only runs as
   bytecode after a dynamic lookup of its own name. Everything that is not a
   method body (root, class bodies, blocks, lambdas) is assumed to run, as is
   every block inside a registered compiled method (bc2cpp may keep one as a
   bytecode proc). A registered compiled body can run as bytecode only before
   its gem_init installs the override, i.e. during mrblib load: that load
   phase is computed separately (`load_phase`), receiver-aware -- no engine
   object exists at load unless load-time code builds one, and the only
   load-time `new` in this tree targets `Struct`/`Color`/`Rect`/`Array`; the
   analysis falls back to a receiver-blind cascade if that ever changes. Every
   other body runs iff its name is dynamic, to a fixpoint. Every SEND-family
   op (including `SENDB`/`SSENDB`, which bc2cpp.rb's own "never called"
   diagnostic was also missing until this change) and `LOADSYM` in runnable
   bytecode counts.
2. **Compiled code's own dynamic dispatch**: every string literal in all three
   gems' generated C++, outside the registration calls themselves. A guarded
   direct call's `mrb_funcall_id` fallback, a POLY dispatch, an interned
   symbol literal or a redefinition guard all intern the name there.
3. **`super`**: the enclosing method's name for every `SUPER`.
4. **Names built at runtime**: every closed-world string-pool literal, and any
   name that starts or ends with a pool literal of two or more identifier
   characters (the real shapes `"#{field}="`, `"#{type}_map_id"`,
   `"#{type}_x"` are present), or ends in `=`/`?`/`!` over a dynamic base.
5. **Everything outside the closed world**, as plain identifier tokens: core
   and core-gem mrblib, the external gems, every other maker gem's mrblib,
   every gem's `test/` (mrbtest runs in the built VM), all of `scripts/` and
   `.github/` whatever the extension (the boot checks feed inline Ruby to the
   binary's `--script`), `tools/`, and every native source in this repository
   and the vendored mruby tree -- closing both gaps docs/adr/0195 found.
6. mruby's implicit protocol names (`initialize`, `to_s`, `each`, `<=>`, ...).

Only `Game::`/`RPG2k::`/`RPG2k3::`/`LCF::` owners are considered, as in
docs/adr/0193: RGSS is the scripting API an RPG Maker XP game's own scripts
call. Wired-embedding owners are eligible: with no dynamic lookup there is no
interpreted fallback left to read the plain iv_tbl, the hazard
`BC2CPP_WIRED_EMBEDDINGS` guards against.

The eligible set is checked in as `tools/bc2cpp/static_dispatch_unregistered.rb`
(179 names today). `bc2cpp.rb`'s `emit_owner_registrations` skips them for
wired owners; `scripts/bc2cpp_prune_static_dispatch_registrations.rb` removed
the 144 hand-written `register.cxx` lines for the rest. The bytecode `def`s are
untouched: `strip_wio_bc2cpp_stubs.rb` still strips them on wio/host, and
nothing dispatches to one either way.
`scripts/bc2cpp_static_dispatch_check.rb` (now in the bc2cpp CI job, next to
the never-called check docs/adr/0193 left as a follow-up) re-proves every
listed name on every run: a later change that adds any dynamic reference to
one fails CI instead of shipping a `NoMethodError`.
`scripts/bc2cpp_wired_embedding_check.rb` exempts listed names.

## Measurement

A/B with `scripts/wio_bc2cpp_measure.bash`, `flock`-serialized, each side in
its own clean worktree. "Without" is master at 8284f44; "with" is this
change on top of it, with the 175-name list that base produced:

| `wio_rgss_boot` link | without | with | delta |
| --- | ---: | ---: | ---: |
| bc2cpp, FLASH overflow | 3,679,444 | 3,663,108 | -16,336 |
| bc2cpp, flash used | 4,187,348 | 4,171,012 | -16,336 |
| baseline (bytecode), FLASH overflow | 684,096 | 684,088 | -8 (noise) |

The bytecode baseline does not link any compiled gem, so its 8 bytes show
the run-to-run noise. RAM is unchanged. In the linked map, each listed
method keeps only its `_impl`: the static wrapper
(`_ZL27Game__Actors_known_invalid_...`, for example) is gone entirely. With
nothing taking its address, the compiler drops it before the linker sees
it. The list checked in is the fixed point on the later master this PR is
based on: 179 names, the same 175 plus 4 that became eligible once the
first pass had dropped their callers' registrations. Those 4 are not in
the measured figure.

An earlier measurement, on a pre-embedding base where 366 names were
eligible, gave -33,072 bytes. docs/adr/0202 and 0204 measured their bc2cpp
rows in a working tree that held that version of this change, so their
absolute bc2cpp figures include it; their deltas do not.

## Consequences

- Residual risk, stated plainly: a method name assembled at runtime from data
  that never appears as a literal or fragment in any scanned source (read out
  of a game file and then `send`) would be missed. Nothing in this codebase
  does that for an RPG2000/2003-internal class today.
- The analysis was cross-checked two ways on the base it was first written
  against: a first, cruder version (every non-compiled irep treated as
  runnable, no load-phase model) produced the identical set, 366 names there,
  and a sample of names was checked by hand against every textual occurrence
  in the repository (each one is only ever a self-call from a compiled
  sibling method).
- Rebased onto master after bc2cpp's optional-argument ivar embedding
  landed, the set shrank from 366 to 179, and this PR's own CI check is what
  caught it. Embedding a class guards every direct call into it with
  MONO_EMBED_GUARD: an exact-class check whose `mrb_funcall` fallback names
  the method. That fallback is a real dynamic lookup (a subclass instance
  misses an exact-class check), so every such name needs its registration.
  All 113 `RPG2k::Scene::Map` names left the list this way. Embedding a class
  and unregistering its methods pull against each other; a guard that fell
  back to the `_impl` for a subclass could win both back.
- Runtime evidence is the real `RPGMAKER_BC2CPP=1` SDL desktop binary
  running `scripts/rpg2k_boot_check.bash` against both test-bed games. Both
  boot to the map with every listed registration gone. The battle runs
  failed identically with and without this change, on a clean baseline.
  That exposed four bugs that predate this change:
  - a `rescue` try body lost its live-in registers (own pull request);
  - a splat call went past 16 `mrb_funcall` arguments (own pull request);
  - accessor devirtualization read embedded ivars from the ivar table (own
    pull request);
  - `registered.tsv` listed compiled methods nothing installs (fixed here,
    as a guard: wiring RGSS::Audio/Graphics in docs/adr/0197 removed the
    instances that bit).
  With all four fixed, every `rpg2k_boot_check` run passed on the bc2cpp
  desktop build at the pre-rebase base. On master at 9c50a10, both battle
  runs fail with "undefined method '+' for NilClass" (an actor's `@agi` is
  nil). It fails identically on master plus only the rescue fix, with no
  registration dropped at all, and with a larger follow-up list applied. So
  it is an upstream regression, not this change.
- Dropping 144 `register.cxx` lines also removed names the native-source
  scan used to find there. That exposed a latent bug:
  `ArgTypes.native_only_mono?` read the registry through its auto-vivifying
  default proc while `analyze` iterated it ("can't add a new key into hash
  during iteration"). It now uses `fetch`.
- mrbtest is **not** evidence either way, and was checked: it runs each gem
  in an isolated state without the `*-compiled` gems, so on a bc2cpp host
  build (bytecode `def`s stripped) it aborts on gaps unrelated to this
  change.
- `bc2cpp.rb`'s "never called" diagnostic now counts `SENDB`/`SSENDB`: a
  method only ever called with a block used to read as never called.
- `build_config.rb`'s `registered.tsv` task now depends on every
  `tools/bc2cpp/*.rb` (the probe had started requiring helpers the old hand
  list did not name, so editing them did not regenerate it).
