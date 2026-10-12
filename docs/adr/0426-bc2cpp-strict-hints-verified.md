# 0426. Strict hints, verified on a sealed desktop host: the candidate-set families had no hint to force

Date: 2026-10-12

## Status

Accepted. Addendum to ADR 0419.

## Context

ADR 0419 left the strict tier unverified ("zero violations is not claimed"): the engine build the
verify procedure needs did not fit the machine it was written on. The closed world the tier forces
is only built for psp, wio and maix, none of which runs on a machine with a display, and the desktop
engine is an open world (XP/VX/Wolf/MV gems, runtime Ruby), where `BC2CPP_STRICT_HINTS` forces
nothing. So the real RPG2000/2003 workloads could not be run against a forced build at all.

## Decision

1. **A sealed desktop host, test-only.** `RPGMAKER_BC2CPP_CLOSED_WORLD_HOST=1` (build_config.rb,
   tools/bc2cpp/compiled_gems.rb) builds the desktop `host` as the same RPG2000/2003-only world wio
   ships (`single_format_only`: no XP/VX/Wolf/MV gems, no onig-regexp; `src/` as the native host;
   the compiled gems closed-world and hot-only). It can only play RPG2k games. The dropped makers'
   init functions are no-ops so `src/main.cxx` links; `mruby-compiler` stays for `--script`. The
   marshal patch drops its onig dependency for this build, and `BC2CPP_KEEP_HAND_REGISTRATIONS`
   keeps the hand-written registrations of a hot-only build (below). Never set for a shipped build.
2. **`-DBC2CPP_HINT_VIOLATION_LOG`** (`BC2CPP_HINT_VIOLATION_LOG=1` in the build): the survey mode of
   the verify build. Each distinct (site, class, name) is printed once as
   `bc2cpp: HINT_VIOLATION_LOG: Class#name at site` and the by-name send runs, so one workload run
   lists every wrong hint instead of stopping at the first abort.
3. `scripts/bc2cpp/strict_hints_verify.bash` runs the workloads (boot, map previews, battles played
   to the end, the map and chipset editors, battle animations on Nepheshel and mtf-meido-action) and
   fails on any violation or abort.

### What the verify run found, and the fix at the source

First run (`BC2CPP_STRICT_HINTS=all`, hot-only sealed host, boot + battle on both games):
10 distinct violations, **all `POLY_SMALL_N`**, none in `IVAR_ACCESSOR`:

| site | receiver class | why the set was incomplete |
| --- | --- | --- |
| `LCF::File#initialize` `schema` | `LCF::Database`, `MapTree`, `MapUnit` | the definers are excluded from a hot-only build |
| `RPG2k#main_loop` `update` | `RPG2k::Scene::Title`, `Module` | an uncompiled definer; a module object with a singleton `update` |
| `Game::State#update_pictures` `update`, `Scene::Map#pictures_signature` `x`, `y` | `Game::Picture` | an excluded definer |
| `Scene::Map#open_message` `transparent=`, `contents=` | `RPG2k::Window` | an embedded accessor left out of the chain |

The candidate set of a name is the list of definers the chain *compiled*. A definer the chain left
out (uncompiled, excluded, an embedded accessor), a core or native definer of the same name, or a
module's singleton definition still answers the name, so its instances reach the else arm in a
correct program. That is the "extra class is legitimate" case of the policy, and it cannot be
widened (a hot-only build, more than 8 classes, unstable classes: `unlisted_class_guards` already
widens what it can). `strict_hint_wrap` now takes the listed classes and keeps the dispatch when
`ClosedWorld#answered_outside?` says a known class outside them answers the name. The 134 + 31 + 0
`POLY_SMALL_N`/`POLY_TABLE`/interface sites ADR 0419 listed were all of this kind (its own table:
`core_or_native`, `singleton_definer`, `unlisted_class`): none is left to force.

Second finding, a hot-only build bug found only because a real workload ran: register.cxx captures
the `g_direct_construct_*` globals behind the `X_compiled_class()` accessors under
`#ifndef BC2CPP_HOT_ONLY_STUBS`, so in a hot-only build every direct construct of a listed owner
read `nullptr` (`Game::Party#initialize` crashed in `bc2cpp_direct_alloc`), and five listed owners
(`Game::Actor`, `Actors`, `Variables`, `Vehicle`, `RPG2k::Window`) have no accessor at all. A hot-only
build now reads the owner-class cache for listed owners too (`direct_construct_class_expr`).
The sealed host always does, so even its full (non-hot) build links.

Third, in the sealed hot-only host `Game.clamp` and `Game.camera_offset` were undefined: the strip
probe counts a hand-written registration as a registration, and `#ifndef BC2CPP_HOT_ONLY_STUBS`
skips those in a hot-only build, where the generated `bc2cpp_register_owner_methods` does not
register module singleton methods. The bytecode `def` is stripped and nothing registers the
method. Not fixed here (wio is not runnable in this environment): the sealed host defines
`BC2CPP_KEEP_HAND_REGISTRATIONS`, and a hot-only wio/maix build should be checked for the same
loss.

Fourth, the verify build aborted at `NilClass#evasion_up` in six troops: a real game bug
(`Party#skill_to_hit` with the AI's nil readiness target) that the interpreted engine also raises;
fixed in its own change (#2191).

## Verified, and not

Verified, on the sealed desktop host with `BC2CPP_STRICT_HINTS=all`, `BC2CPP_NOMETHOD_VERIFY` and
`BC2CPP_HINT_VIOLATION_LOG` (final code, `strict_hints_verify.bash`): 78 runs of the full build
(30 forced sites: IVAR_ACCESSOR 16, TYPED 13, ELEMENT 1) and 78 runs of the hot-only build (36
IVAR_ACCESSOR sites), on Nepheshel206 and mtf-meido-action: New Game to the map, 29 map previews, 38
troops played to the end, both editors, 5 battle animations. **0 violations, 0 verify aborts.**
`strict_hints_check`, its mutation check (16 mutants) and `strict_hints_reviewed_check` pass.

Sends in the generated wio closed world (`bc2cpp_send(M` plus `mrb_funcall*` stay at ~408, counted in
the raw generator output, three compiled gems plus core), full build / hot-only build:

| | default | `=1` | `=all` before | `=all` after |
| --- | ---: | ---: | ---: | ---: |
| `bc2cpp_send(M` | 1890 / 783 | 1850 / 738 | 1671 / 651 | 1850 / 738 |
| forced sites | 0 | 41 / 45 | 229 / 132 | 41 / 45 |

`=all` before forced POLY_SMALL_N 156 / 87 and POLY_TABLE 32 / 0 sites that the run showed to have
other legitimate receivers; the 10 distinct violations above were the ones the workloads reached.

Not verified: the 19 of the 30 full-build sites whose containing method no workload entered
(PARAM_TRACE `entries` 0: the debug menu and map-viewer sites, save/load/exit event commands,
`Game::Troop#total_exp`, `Scene::Battle#draw_battle_gauge_face`, ...). They are unrefuted, not
proven. Optcarrot has no forced site (its sealed world compiles 17 methods; checksum 59662
matches). mruby's `rake test` cannot test the compiled gems (they are initialised by the dispatch,
not by `mrb_open`; `mruby-lcf` tests then see no `LCF::File#initialize`). `param_trace_report.rb`
lists 13 "contradictions" that are all its `FILE:`/`ROW:`/`TABLE:` class tokens (the observed class
is the named one): a report artefact, not a wrong fact. No mutant covers the new
`answered_outside?` gate yet.

## Consequences

- `all` forces exactly the sites `1` does on the wio closed world: the candidate-set families have
  no hint to force. They stay selectable (a world with no outside definer gains sites) but add
  nothing today; `1` is not widened.
- `tools/bc2cpp/strict_hints_reviewed.rb` shrinks to the sites that survived.
- The default output is unchanged except in hot-only builds (the accessor above).
