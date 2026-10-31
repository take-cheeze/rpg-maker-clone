# Unified method-table inventory

The closed-build inventory combines the engine/RGSS retention report and the remaining core/runtime entries. The baseline audit at `3777da393` counted 1,252 installed entries and reconciled every one of the earlier report’s 446 owner/name pairs. Function addresses were resolved against the host binary to distinguish native implementations from generated C++ wrappers.

## First native-registration reduction

Candidate discovery now accepts any callable expression when the native registration’s owner and method name are fixed. A lambda or template specialization does not make the installed method key dynamic. The existing reachability proof still excludes aliases, Ruby overrides and computed-name owners, and retains names looked up inside callable bodies.

The proof reached a fixed point after two passes: the closed list grew from 3,564 to 3,584 keys, while the open list (1,143), core ROM exclusions (152) and core runtime removals (104) stayed unchanged. Runtime enumeration confirmed exactly these 20 additional removals:

- `RGSS::Color`: `red`, `green`, `blue`, `alpha`, and their setters (8).
- `RGSS::Tone`: `red`, `green`, `blue`, `gray`, and their setters (8).
- `RGSS::Rect`: `set`, `y`, `y=`, `height=` (4).

The installed table falls from **1,252 to 1,232 entries**. The threshold in `scripts/bc2cpp/method_table_threshold.txt` records the reduced count. These are entry counts, not measurements of backing-table capacity or binary size.

## Native alias reduction

Native alias destinations now participate in the core runtime-removal proof.
The new name defines a table entry, while the source name remains a lookup.
Alias chains therefore retain their sources; computed owners, reachable names,
fragment-built names and keys shared with ROM entries stay protected.

Against the `e83fd22bb` baseline, the proof reached a fixed point after two passes. Core runtime
removals grew from 104 to 107; the other lists stayed unchanged. Runtime
enumeration confirmed exactly three removals: `Integer#modulo`, `Float#modulo`
and `Module#attr`. Their source methods (`%` and `attr_reader`) remain installed.
The table now contains **1,229 entries**, down from 1,232 after the first batch.
This measures entries, without claiming a reduction in allocated table capacity
or a generator speedup.

## Combined inventory after both reductions

| Category | Native | Compiled C++ | Undefined | Total |
| --- | ---: | ---: | ---: | ---: |
| Collections, strings and enumeration | 186 | 162 | 0 | 348 |
| RGSS | 113 | 51 | 0 | 164 |
| Game | 0 | 147 | 0 | 147 |
| Numeric, math and random | 92 | 20 | 2 | 114 |
| IO, files and StringIO | 81 | 34 | 0 | 115 |
| Object model and top-level protocols | 94 | 4 | 1 | 99 |
| RPG2k | 2 | 95 | 0 | 97 |
| LCF | 6 | 30 | 0 | 36 |
| Symbols, booleans and nil | 26 | 6 | 4 | 36 |
| Time | 22 | 0 | 0 | 22 |
| Fiber, Proc and GC | 16 | 0 | 0 | 16 |
| RPG2k3 | 0 | 15 | 0 | 15 |
| Exceptions | 12 | 2 | 0 | 14 |
| Marshal | 6 | 0 | 0 | 6 |
| **All entries** | **656** | **566** | **7** | **1,229** |

No method-table entry points to Ruby bytecode. This does not count standalone blocks or startup bytecode. The seven undefined markers preserve method undefinitions: singleton `new` on Integer, Float, Symbol, TrueClass, FalseClass and NilClass, plus `Class#module_function`.

## Rechecking

`scripts/bc2cpp/static_dispatch_scan_check.rb` covers lambda/template/function-expression candidates, callable-body lookups, alias exclusions, computed names/owners, Ruby overrides and existing candidates. `scripts/bc2cpp/unregistered_verify_check.rb` exercises ordinary removal, preserved `respond_to?` answers and aborting verify stubs even when no named callable is available.

`scripts/bc2cpp/core_native_candidates_check.rb` also checks native alias
destinations, chains, source lookups, computed owners and ROM-sharing exclusions.
The runtime verify fixture removes a native alias, confirms its source still
answers, and deliberately calls the removed alias to check the aborting trap.

Build with `scripts/bc2cpp/closed_build.bash BUILD_DIR`, then run `scripts/bc2cpp/host_sweep.bash BUILD_DIR GAME_DIR`. Repeat with `BC2CPP_UNREGISTERED_VERIFY=1` and `METHOD_TABLE=skip`: the verify build registers traps under removed names, so its table count is intentionally different. The plain host count is available through `BC2CPP_HOST_MT_COUNT=1 BUILD_DIR/trace-host/trace_host GAME_DIR 1`.

The first reduction passed the New Game, battle, menu, save/load and 543-map
sweeps in both plain and verify builds. A deliberately forced lookup of removed
`RGSS::Color#red` aborted with the expected `UNREGISTERED_VERIFY` message,
confirming that the verify traps were active.

The alias reduction passed the same scenarios and 543-map sweeps in plain and
verify builds. Deliberate calls of each of the three removed aliases aborted
with its expected `UNREGISTERED_VERIFY` diagnostic. Independent count-only and
per-entry dumps both reported 1,229 entries; the dumps also confirmed that all
three alias sources remain installed.
