# 0422. bc2cpp compiles Game::CommonEvent.singleton and Game::MoveRoute.singleton; a keyword `new` in a class method

Date: 2026-10-12

## Status

Accepted

## Context

ADR 0416 binds `Const.name(args)` to a native singleton function and left the Ruby-defined singletons that already pass the
ADR 0259 proof (`CLOSED_WORLD_CONSTANT_OBJECT`) unfinished. Its follow-up list named four groups; this ADR measures each
against the tree instead of the report that produced the list (`BC2CPP_NSC_DEBUG=1` prints the refusal of every site):

| site (caller) | refusal on master | what it actually was |
|---|---|---|
| `Game::CommonEvent.load` (`Scene::Map#initialize`) | `owner_not_emitted` | `Game::CommonEvent.singleton` is not in the owners of `mruby-rpg2k-compiled` |
| `Game::MoveRoute.same_route?` (`Scene::Map#rebuild_events_preserving_positions`) | `owner_not_emitted` | `Game::MoveRoute.singleton` is not in the owners |
| `Game::MoveRoute.from_page` (`Scene::Map#build_event`) | `candidate_not_compiled_clean` | not rescue (a whole-method `rescue StandardError` compiles since ADR 0145): the body's `new(cmds, repeat: r, skippable: s)` is an implicit-self `SSEND :new` with keywords, and `compile_keyword_direct_construct` (KEYWORD_DIRECT_CONSTRUCT_SUPPORT) returned nil for any implicit self. The error is `SEND/SSEND :new has a splat and/or keyword argument list (n=1\|nk=2)` |
| `Game.rpg2003_database?` (`Game::Party`) | `candidate_not_compiled_clean` | not unsupported: the method compiles. The probe is a cycle, `Game::Party#rpg2003?` calls `Game.rpg2003_database?(db)` which calls `db.rpg2003?` (three definitions), so the candidate's cleanliness depends on itself and `compiles_clean?` answers false while it is being probed. `BC2CPP_NSC_DEBUG` now says `candidate_not_compiled_clean(cycle)` (and `core_guarded`, `resumable`, `error_marker`) instead of one name |
| `LCF.field?`, `read_ber`, `elements_of` | `no_irep` | native or accessor targets: nothing to compile |

The owners list is the only thing keeping the first two from binding, and `register.cxx` is where the flash question is.
`register.cxx` registers a full build's compiled entries by hand inside `#ifndef BC2CPP_HOT_ONLY_STUBS`. A hot-only build
(wio, psp, maix, ADR 0214) skips that region and compiles only the methods of `tools/bc2cpp/hot_methods.txt`; none of
`CommonEvent.load`, `.eligible`, `MoveRoute.from_page`, `.same_route?` is listed (map-load paths, not frame paths).

## Decision

1. `Game::CommonEvent.singleton` and `Game::MoveRoute.singleton` are owners of `mruby-rpg2k-compiled`
   (`tools/bc2cpp/compiled_gems.rb`), and the four methods are registered by hand next to `Game::Backdrop.singleton`,
   inside the full-build region (`load`, `eligible`, `from_page`, `same_route?`). Neither is a wired embedding: a
   `.singleton` owner never embeds.
   `from_page` is registered only when the generator emitted it. The desktop build is a full build but not a closed
   world, so KEYWORD_IMPLICIT_NEW (item 2) refuses it there and `SKIP_UNSUPPORTED` drops it (it stays bytecode); a hand
   registration that named `Game__MoveRoute_singleton_from_page` was an undeclared identifier in that build (CI
   `bc2cpp-build`). The generator now writes `#define BC2CPP_SKIPPED_<entry> 1` for every entry it dropped, and
   `register.cxx` wraps the `from_page` registration in `#ifndef BC2CPP_SKIPPED_Game__MoveRoute_singleton_from_page`.
   `load`, `eligible` and `same_route?` compile in every world and need no guard.
2. KEYWORD_IMPLICIT_NEW. `compile_keyword_direct_construct` accepts an implicit-self `new(a, k: v)` when
   `implicit_singleton_self_class` names the class (the same evidence the positional path uses: the registry's
   `X.singleton` owner, emitted by this build) **and** the closed world proves the class has no descendants
   (`exact_class?`). The second condition is not in the positional path: a subclass inherits a class method, so `self`
   can be the subclass, the generated `mrb_class_ptr(self) == X_compiled_class()` test then misses, and the guard-miss
   arm packs the keywords into a trailing positional Hash, which a funcall to a keyword `#initialize` does not accept
   (`wrong number of arguments (given 2, expected 1)`; the check's subclass world found this, it was not reasoned out).
   With no descendants the miss is only a constant reassigned after the gem's init, the case the arm was written for.
   A bare `new` in an instance method (self is not a class) never qualifies.

## Consequences

Measured on the wio closed world's shipped pass (`SKIP_UNSUPPORTED=1`, all owners, master 7714f4d0 plus this change):

| | live `bc2cpp_send(M` | live `mrb_funcall*` | `origin=constant_lookup` | bound `MONO` sites for these methods |
|---|---|---|---|---|
| ADR 0416 tree | 1796 | 394 | 15 | 0 |
| this change | 1797 | 397 | 12 | 3 (`load`, `from_page`, `same_route?`) |

The three sites are direct C++ calls (no `mrb_funcall`, so no by-name send at all). The send count does not fall: three
sites left it and the newly compiled bodies add four of their own (record accessors, `$stderr.puts`, a loop's
dispatch fallbacks), which the interpreter used to run as `OP_SEND`. The gain is three calls and four bodies off the
interpreter, on map-load and event-rebuild paths, not a lower send count. Stated plainly so the number is not mistaken
for a win it is not.

Flash:

- **Hot-only builds (wio, psp, maix): zero.** The generator run with `BC2CPP_HOT_METHODS=tools/bc2cpp/hot_methods.txt` and
  the rpg2k owners, with and without the two new ones, differs by exactly four
  `[[maybe_unused]] static constexpr bc2cpp_hot_only_excluded Game__...` empty-object declarations and a changed
  comment count (2538 to 2542 entry points not compiled). Nothing references them, no code or data is emitted,
  and `register.cxx`'s region is skipped. `scripts/bc2cpp/rpg2k_singleton_owners_check.rb` asserts that the fixture
  generated with the real hot list holds no definition of the four, that the list does not name them, and that the
  registrations are inside the guarded region.
- **Full builds (desktop): about 7.8 KB of code for about 2.0 KB of bytecode.** A real `env:wio_rgss_boot` link was not
  taken: it needs `MRUBY_TARGET=wio` builds of both configurations (two mruby cross builds and the PlatformIO link, tens
  of minutes and several GB) on a box with 3.5 GB free that another job shared. Instead the four methods' generated file
  (the two new owners plus `Game::MoveRoute` and the record class their bodies construct) was compiled with the same
  arm-none-eabi 14.2.1, `-Os -mcpu=cortex-m4 -mthumb -ffunction-sections -fno-rtti`, against the patched headers (the wio
  defines are approximated, so this is a proxy): `load` 1.4 KB (entry, rescue try body, block body), `eligible` 1.8 KB,
  `from_page` 0.7 KB, `same_route?` 3.8 KB, 7,810 bytes in all; the same four methods are 2,565 - 524 = 2,041 bytes of
  bytecode in mrbc without debug info. Net about +5.8 KB, 1.1% of the 507,904-byte FLASH region, on a target that does not
  build this way. For a flash-limited build the number that matters is the first one.
  The wio image already overflows (ADR 0400: a 1,023,608-byte image against a 507,904-byte region), so no headroom was spent either way.

`scripts/bc2cpp/rpg2k_singleton_owners_check.rb` slices `module CommonEvent` and the two class methods out of
`mruby-rpg2k/mrblib/game.rb` with Prism (so the fixture cannot drift from the engine), adds a stub `MoveRoute#initialize` with
the engine's signature, and runs: generated code for the base world and three withdrawal worlds (a redefinition of
`same_route?`, a subclass, an open world), then 28 cases on real mruby, interpreted against compiled (values,
exceptions, the messages a failed load or comparison writes to `$stderr`), and the wiring assertions above.
`rpg2k_singleton_owners_mutation_check.rb` breaks the eleven conditions (the three of KEYWORD_IMPLICIT_NEW, an open
world, the two owners, a third gem owning one, a removed registration, a registration moved out of the full-build
region, a hot list that names the method); all are killed and none was dropped to make the run pass. The shard is
`rpg2k-singleton-owners`. Not run in the PR job.

## Not done, and what is missing

- `File.open` / `IO.open` (about 8 sites). Measured with the same pass: `IO.singleton#open` is "unhandled opcode EXCEPT";
  `IO.singleton#popen` and `File#initialize` ("unhandled opcode SUPER") are left interpreted too. Rest plus block is
  **not** the blocker in project code (`REST_BLOCK_COMBINED_SUPPORT`); the blockers, in order:
  1. `begin yield io ensure begin io.close unless io.closed? rescue StandardError end end` has two catch handlers in one
     irep, an `ensure` and a `rescue` nested in the ensure body. `recognize_ensure_region` requires exactly one handler and
     rejects `EXCEPT` and `RAISEIF` in the ensure body (the body is a destructor lambda). A nested rescue needs the
     rescue region lifted out of the ensure lambda (its try body, `mrb_protect_error`, its glue) with the lambda's
     fall-off-the-end contract, and every exit of the yield (normal, `break`, a non-local `return`, an exception) must
     run it exactly once;
  2. `File#initialize` is `super(fd, mode)` into the native `IO#initialize`: SUPER to a native target, plus the optional
     `perm`;
  3. binding `File.open` needs the singleton lookup to continue to `IO.singleton` (today `File.open` is
     `no_unique_singleton_def`), with `self.new(*args)` staying a dynamic send on the receiver (it may be `File`, `IO` or a
     subclass), so the callee cannot assume its class;
  4. the behavioural worlds: open failure, a block that returns, breaks, raises, closes the file itself, and a `close`
     that raises, each against the interpreter.
  Estimate: 1 to 1.5 weeks including the mutation worlds, for about eight sites (0.4% of the by-name sends) on file-open
  paths dominated by the open itself. Not shipped half-done.
- `Game.rpg2003_database?`: the cycle above. Breaking it needs the probe to assume the candidate clean for its own
  recursive query and verify afterwards, which is a change to `compiles_clean?` used by every direct arm.
- `LCF.field?`, `read_ber`, `elements_of`: nothing to compile.
