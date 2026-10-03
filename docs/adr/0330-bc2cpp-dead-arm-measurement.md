# 0330. bc2cpp: are the proven-error arms reachable? Measured per site, with a report (nothing built)

Date: 2026-10-03

## Status

Accepted

## Context

The wio closed world ships 4,441 `bc2cpp_nomethod` arms (the else of a receiver-class chain that no class outside the
chain answers, ADR 0210) and 879 `bc2cpp_nil_receiver` arms (the nil path of a receiver proven nil-or-one-class, ADR 0296).
Each can only raise `NoMethodError`. ADR 0226 has a person review every `nomethod` key as "the receiver always has a
listed class" (dead) or "a real missing method". ADR 0317 measured the provable errors (no class answers, nil receiver,
wrong argument count, operators) at 0 engine hits and left them as warnings; ADR 0275 makes a proven-class miss a build
error, with an empty `PROVEN_MISS_REVIEWED`.

The question was whether that still holds, and whether any arm that can be reached from a live entry point is a real
latent bug (the engine would raise `NoMethodError`, `ArgumentError` or `TypeError` if it ran).

## Decision

A measurement only. No generated code changes (`shipped.cxx` and its stderr of the `scripts/bc2cpp_coverage_report.rb`
shipped pass are byte-identical with the report on and off, both compared with `cmp`).

* `BC2CPP_DEAD_ARM_REPORT=<tsv>` (`tools/bc2cpp/dead_arm_report.rb`, columns in `dead_arm_report_columns.rb`) writes one
  row per arm with: the shape of its send, whether its method body can be called, whether a rescue, a probe, a store
  or a branch on the receiver guards it, the receiver's origin (an ivar read with its nil source: whether `initialize`
  sets it, which methods set it and which reset it to nil) and a call path from an entry. Other rows: `partial_miss`
  (a send whose proven receiver class set holds a non-nil class that does not answer the name), `const_unresolved`
  (a constant nothing defines), `arity_all` / `arity_some` (a plain call every / some Ruby definition of the name rejects).
* `scripts/bc2cpp_dead_arm_report.rb da.tsv [--lcov coverage/lcov.info] [--list]` prints the tables below; `--lcov`
  (from `scripts/coverage_report.rb`) adds whether a passing CRuby check ran the site's line, `--list` every REACHABLE
  site with `file:line`.
* `scripts/bc2cpp_dead_arm_report_check.rb` (generated code only, about 15 s, `call-facts` shard): the report changes
  no output, and a fixture with a chain else, a nil path, a rescue, an uncalled method, a store before the read, an exact
  receiver that lacks the name, undefined and rescued constants and a wrong argument count gets the rows it should.
* One hook line in `tools/bc2cpp/bc2cpp.rb`; `provable_error_report.rb` writes at exit only when its own variable is set,
  so `dead_arm_report.rb` can reuse its receiver class sets.

Classes (exclusive, first match wins): (d) the method body is not callable, (e) a rescue, a probe of the name
(`respond_to?` and friends), a store of a non-nil value just before the read (`selfset`) or an earlier branch on the
same value (`hint`) guards the site, (b) the arm is the only arm of its send, (c) the arm is a nil path, (a) the else of a
send with live arms. "Callable" is a by-name call-graph fixpoint from the names native code sends (`NATIVE_SRCS`, the wio
and desktop mains), `initialize`-style names mruby calls, and every class body; a symbol literal counts as a call. It
over-approximates live, so DEAD is the trustworthy answer, except that a name native code computes at run time
(`src/main.cxx` sends `effect_probe` / `window_probe` through a variable) is invisible: 31 of the 32 rgss "dead" arms are
those two probes.

## Measured

Master `49f39416`, wio closed world, `3rd/*` populated, host `mrbc` of mruby 4.0, shipped pass of
`scripts/bc2cpp_coverage_report.rb`. 5,335 arm rows (4,457 `nomethod`, 878 `nil_receiver`; the shipped C++ has 4,441 and
879: the 17 differences are not reconciled, the rows are the last compile of each send, shipped or not).

| Class | Arms | Meaning |
| --- | ---: | --- |
| (a) dead fallback of a send with live arms | 2,739 | the normal case: `if class == A {..} else raise` |
| (b) the only arm of its send | **0** | a send that always raises |
| (c) nil path of a nil-or-one-class receiver | 822 | unguarded, live |
| (d) unreachable method body | 86 | 20 core, 32 rgss (31 are native-called probes), 34 rpg2k |
| (e) guarded | 1,688 | probed 1,166, rescue 417, hint 76, selfset 29 |

(c) with a guard is another 248 (rescue 76, probed 67, hint 76, selfset 29; in the table above they are in (e)), dead 56.
Per gem: rpg2k 5,201 arms, rgss 54, lcf 17, core 62 (all (d) or (e)), other 1.

No send is a sole arm: a send whose proven receiver classes all lack the name keeps its dynamic dispatch (the fixture
check pins this) and `PROVEN_MISS` (0 sites) is the build error for it. The other must-raise shapes of the engine gems:

| Shape | Sites |
| --- | ---: |
| `partial_miss`, shape `all` (no proven class answers: the provable error of ADR 0317) | **0** |
| `partial_miss`, shape `some` (a non-nil member of the proven set lacks the name) | 88, one cluster (below) |
| `arity_all` (every Ruby definition of the name rejects the argument count, no native or foreign one answers) | **0** |
| `arity_some` (some definition rejects: an upper bound of the direct entries the repo refuses on arity) | 606 (3 dead) |
| `const_unresolved` (nothing in the engine, the wio sources or core defines the constant) | 14 rows, 11 names, all inside `rescue NameError` |
| `ProvableErrorReport` (ADR 0317): operators, `Integer / 0`, nil receiver exactly nil, no class answers | 0 (its one row is an `undefined_name` the probe guard excludes) |

`arity_some` is a name-level bound, not a count of refusals: `new`, `initialize` and `update` are defined with several
arities in different classes. The constants (`TEST_PLAY`, `RPG2K_NEW_GAME`, `RPG2K_PREVIEW_MAP`, `RPG2K_SCREEN_WIDTH`, ...) are defined by the
desktop `src/main.cxx` and not by the wio mains; each use is a method whose body is the constant under `rescue NameError`
(`RPG2k#native_test_play?`, `Scene::Base#screen_width`, the title/battle/preview request readers), which is the intended probe.

### The 822 REACHABLE (c) sites

All 822 sit in compiled methods reachable by name from a native entry (746) or a class body (76); none is in a method
nothing calls. By receiver origin:

| Origin | Sites | Verdict |
| --- | ---: | --- |
| an ivar a `start` / `build_*` / `open_*` method sets and a `dispose` / `close_*` resets (81 class-ivar clusters; `init:unset` 515, `init:nil` 64, `init:value` 68) | 647 | lifecycle state: nil before setup or after teardown |
| a database chunk or element (`db[:system][:battle_music]`, `@db[:item][id]`, `db[:term]`) | 152 | nil only for a database file that lacks the chunk |
| a method parameter | 19 | callers guard (below) |
| other call results, upvar | 4 | below |

The largest clusters are `Scene::Battle#@ui` 379 (set in `start`, `dispose` sets it nil), `Scene::Map#@name_ui` 47,
`Scene::Map#@shop` 16, `Window#@skin_bmp` / `@cursor_bmp` 30 (set in `allocate_skin`, the last line of `initialize`),
`DebugMenu#@editor` 17, `RPG2k#@scenes` 14, and the `Scene::Map` sprite and layer ivars set in `setup_sprites`.
688 of the 822 lines were executed by a passing `scripts/coverage_report.rb` check (CRuby harnesses, 94% of the rpg2k
Ruby), 52 were not, 82 have no line data. Executing a line without a `NoMethodError` shows that nil did not reach it on that
run, not that it cannot.

Read by hand (the setters, the order in the constructors and `start`, the callers): the `@ui`, `@name_ui`, `@shop`,
`@editor`, `Window` bitmap and `Scene::Order` / `Menu` / `Title` window clusters (every reader runs after the `build_*`
the constructor calls; `Menu#build_windows` sets `@command` before `refresh_cursor` and `@status` before any status
reader); `RPG2k#@scenes` (assigned in `initialize` before `boot_title_or_new_game`); `Scene::Map#initialize` (`setup_sprites`
then `render`, and `setup_sprites` reaches `setup_pictures` and `setup_screen_overlay`); `Game::Troop#apply_appear_randomly`
(its only call is `... if row && rng`); `MoveType.random_direction` (`world` is `Scene::Map#@world`, set before any step);
`RPG2k#bug_report_text` (`@events = []` runs in `build_events` before the scene is pushed); `Game::Enemy#initialize`
and `LCF::Array2D#initialize` (`@attribute_ranks = {}` / `@data = []` is written earlier in the same method: the flow
does not track ivar stores across a branch). The 150 database reads and the 647 ivar sites were read as clusters, not line
by line; the remaining sites of a cluster share the setter and the lifecycle.

**Real latent bugs: none found.** What the reading did turn up:

* Imprecision of the ivar pools (ADR 0295): a pool is one per (family, name), so the nil source of an ivar is any class of
  the family. `Scene::Map#@message` (a `MessageState` or nil) is pooled with `Scene::Menu#@message` (a Hash), which is
  the whole of the 88 `partial_miss` rows (`pause_frames`, `seg_lines`, `window` ... "missing" on `Hash`). `@pending`
  (4) is `[]` in every store of `Game::Battle`. The nil of such an arm is not a store in the class, so a per-class pool would
  drop it.
* Inconsistent robustness: `Scene::Map#battle_bgm`, `victory_bgm`, `inn_bgm`, `vehicle_*`, `Game::Shop#price` /
  `name` / `description` / `equip?`, `RPG2k#show_title?` read `db[:system][...]` / `@db[:item][id]` without
  `LCF.field?` while other readers guard it. A conforming `RPG_RT.ldb` has the chunk; a database without it would raise
  there. Intentional or not is for the maintainers; nothing was changed.
* The nil arms of index ops (`rows[i].field`, `db[:x][id]`: a missing row or chunk is nil) are only as precise as the
  element classes of the Hash or Array literal they read.

## Would provable errors as compile errors remove anything?

No. Every kind that is provable today has 0 sites: sole arms 0, `partial_miss` shape `all` 0, `arity_all` 0, operators 0,
`Integer / 0` 0, nil receiver exactly nil 0, `PROVEN_MISS` 0. A build error on all of them would not trip on the engine, and
would fail the fixtures only. The 14 `const_unresolved` rows would fail a "constant nothing defines" error: they are the
desktop-only constants behind `rescue NameError`. The nil arms (c), 822 unguarded plus 248 guarded, are the only
non-empty class and cannot be errors: the proof is "nil or K", not "nil".

## Consequences

* The by-name census, the 0317 measurement and the 0226 review gain a per-site list with its origin; the next receiver
  proof can be judged by how many (c) and (a) arms it removes, and the 647 ivar sites are the work list for a per-class ivar
  pool.
* A sound lifecycle proof for those 647 sites would need, per scene class, "every reader is called only after the
  `build_*` method that sets the ivar"; that is a by-name call-graph property per class, not per name. It would remove
  `nil_receiver` arms and their `mrb_iv_get` + nil test, not a dispatch.
* Not run: no generated code changed, so no mutation check, no full-core / core-only / 32-bit `mrb_int` build, `mruby_test`,
  psp or wio smoke run. `scripts/coverage_report.rb` was run once for the coverage column; `pre-commit` and
  `scripts/bc2cpp_dead_arm_report_check.rb` are in the pull request.
