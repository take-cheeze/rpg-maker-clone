# RPG2k-only dependencies

The `closed`, `psp`, `wio` and `maix` builds ship RPG Maker 2000/2003 only.
Those games carry event commands rather than Ruby game scripts. Their saves
use LCF `.lsd` data; the old Marshal `save<N>.mrb` format is no longer loaded.

These builds omit dependencies used only by the other makers:

| Dependency | Why it can be omitted |
| --- | --- |
| `mruby-marshal` | RPG2k uses LCF data and saves. RGSS's native `_dump`/`_load` callbacks operate on byte strings without calling Marshal. |
| `mruby-struct` | No RPG2k runtime source constructs a Struct; Marshal was its remaining consumer. Compiled core must not request it independently. |
| `mruby-kernel-ext` | The runtime does not call its factory/convenience APIs such as `Integer()` or `caller`. |
| `mruby-random` | RPG2k uses its own seeded LCGs rather than `Random`, `rand`, `shuffle` or `sample`. |

Multi-format desktop, browser and Android builds retain the game-script
dependencies. RPG Maker XP declares its Marshal dependency directly. The
shared RGSS gem declares Marshal as a test dependency for serialization
round-trips, and keeps a runtime dependency on metaprogramming because its
tilemap allocation probe uses `instance_variable_get`.

Onigmo was already excluded from the pinned Marshal gem's RPG2k-only closure;
this change does not newly remove it. StringIO, packing, Math, Fiber and other
dependencies still used by the runtime or its declared providers remain.

The bc2cpp canonical source set excludes Struct, and the compiled-core gem
only orders itself after Struct when that gem is actually loaded. Dependency
closure analysis mirrors this condition, so it cannot silently pull the
omitted gem back in.

## Checks

`ruby scripts/bc2cpp/compiled_gems_config_check.rb` checks the dependency matrix,
transitive closure, test/runtime declarations and optional compiled-core edge.
`ruby scripts/wio/dropped_gems_check.rb --rpg2k` rejects runtime calls to omitted
APIs across the shared Ruby and single-format native sources. The default mode
also checks Wio's smaller Math API.

`scripts/bc2cpp/host_sweep.bash BUILD_DIR GAME_DIR` verifies at startup that
Marshal, Struct, Random and the omitted Kernel factories are absent, then tests
the game scenarios, save/load and every map. It performs the dependency check
in both plain and unregistered-method verify builds.
