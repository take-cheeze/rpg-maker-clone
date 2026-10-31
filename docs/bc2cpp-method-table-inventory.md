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

## Ruby alias operand reduction

The core scan now reads both `ALIAS` operands from the RITE binary instead of
retaining every symbol in a class body containing an alias. The source and
destination names still count, including operator names; unrelated definitions
do not become live just because they share that body. An unresolved source
operand retains every symbol conservatively.

The proof adds 23 core ROM exclusions and three runtime removals, with the open
and closed engine lists unchanged. The additional entries are:

| Owner | Removed names |
| --- | --- |
| Array | `__combination_init`, `__combination_next`, `__fill_exec`, `__fill_parse_arg`, `__product_generate`, `__product_next`, `flatten`, `flatten!` |
| String | `capitalize`, `capitalize!`, `casecmp`, `casecmp?`, `downcase`, `downcase!`, `partition` |
| IO | `readchar`, `sync`, `sync=`, `sysread` |
| File | `truncate` |
| Integer, Float | `truncate` on each |
| Exception | `exception` |
| Kernel | instance and singleton `sprintf` |
| StringIO | `rewind` |

The table falls from **1,229 to 1,203 entries**. The threshold records this new
count. These remain entry counts; allocated table capacity and generator speed
are not measured here.

## Unused compiled core Ruby reduction

The general receiver-blind proof now also considers Ruby-defined core methods,
including methods compiled to C++. A candidate must have a fixed, unambiguous
owner and no reachable name, fragment-built name or direct compiled call.
Explicit public sends still count as lookups. Keys shared with ROM entries
stay protected to avoid replacing a readonly entry with a RAM tombstone.

Runtime enumeration confirms exactly **75 compiled entries removed**, taking the
table from **1,203 to 1,128 entries**, with no additions. Core runtime removals
grow from 110 to 185; core ROM exclusions (175), open (1,143) and closed (3,584)
engine lists stay unchanged. The removed entries are:

| Owner | Removed names |
| --- | --- |
| Array | `__repeated_combination`, `bsearch`, `bsearch_index`, `combination`, `dig`, `fetch_values`, `fill`, `keep_if`, `permutation`, `product`, `repeated_combination`, `repeated_permutation`, `reverse_each`, `rfind`, `transpose` |
| Comparable | `between?` |
| Enumerable | `cycle`, `drop`, `drop_while`, `each_cons`, `each_entry`, `each_slice`, `grep`, `grep_v`, `group_by`, `max_by`, `min_by`, `minmax`, `minmax_by`, `one?`, `partition`, `reverse_each`, `take`, `take_while`, `tally` |
| Enumerator | `feed`, `peek`, `peek_values`, `rewind` |
| File singleton | `foreach` |
| Hash | `dig`, `fetch_values`, `flatten`, `invert`, `keep_if`, `transform_keys`, `transform_keys!`, `transform_values`, `transform_values!` |
| IO | `each_byte`, `printf`, `rewind` |
| Integer | `allbits?`, `anybits?`, `ceildiv`, `integer?`, `nobits?` |
| Numeric | `integer?`, `nonzero?` |
| Range | `overlap?` |
| String | `each_byte`, `gsub`, `gsub!` |
| StringIO | `fsync`, `read_nonblock`, `readchar`, `sync`, `sync=`, `sysread`, `write_nonblock` |
| Struct | `dig` |
| Symbol | `capitalize`, `casecmp`, `casecmp?`, `downcase` |

The closed build omits these registrations and load-time Ruby definitions.
Generated C++ implementations can remain until the linker discards unused
sections. Other builds retain the registrations. These are entry-count
measurements; table capacity and generator speed are not measured here.

## Combined inventory after all four reductions

| Category | Native | Compiled C++ | Undefined | Total |
| --- | ---: | ---: | ---: | ---: |
| Collections, strings and enumeration | 171 | 109 | 0 | 280 |
| RGSS | 113 | 51 | 0 | 164 |
| Game | 0 | 147 | 0 | 147 |
| Numeric, math and random | 90 | 13 | 2 | 105 |
| IO, files and StringIO | 75 | 23 | 0 | 98 |
| Object model and top-level protocols | 92 | 4 | 1 | 97 |
| RPG2k | 2 | 95 | 0 | 97 |
| LCF | 6 | 30 | 0 | 36 |
| Symbols, booleans and nil | 26 | 2 | 4 | 32 |
| Time | 22 | 0 | 0 | 22 |
| Fiber, Proc and GC | 16 | 0 | 0 | 16 |
| RPG2k3 | 0 | 15 | 0 | 15 |
| Exceptions | 11 | 2 | 0 | 13 |
| Marshal | 6 | 0 | 0 | 6 |
| **All entries** | **630** | **491** | **7** | **1,128** |

No method-table entry points to Ruby bytecode. This does not count standalone blocks or startup bytecode. The seven undefined markers preserve method undefinitions: singleton `new` on Integer, Float, Symbol, TrueClass, FalseClass and NilClass, plus `Class#module_function`.

## Rechecking

`scripts/bc2cpp/static_dispatch_scan_check.rb` covers lambda/template/function-expression candidates, callable-body lookups, alias exclusions, computed names/owners, Ruby overrides and existing candidates. `scripts/bc2cpp/unregistered_verify_check.rb` exercises ordinary removal, preserved `respond_to?` answers and aborting verify stubs even when no named callable is available.

`scripts/bc2cpp/core_native_candidates_check.rb` also checks native alias
destinations, chains, source lookups, computed owners and ROM-sharing exclusions.
The runtime verify fixture removes a native alias, confirms its source still
answers, and deliberately calls the removed alias to check the aborting trap.
The same core candidate check covers decoded Ruby alias sources (including an
operator), unrelated definitions beside an alias, source-body liveness and the
conservative unresolved-operand fallback.
It also checks unused public and singleton core definitions, direct compiled
calls, public sends, Symbol lookups, fragments, ROM sharing and ambiguous
owners. `scripts/bc2cpp/static_dispatch_lists_check.rb` checks that core removals
apply only to closed builds.

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

The Ruby alias operand reduction was rechecked on `a62699052`. Plain and verify
builds passed the same scenarios and all 543 maps. Runtime enumeration found
exactly the 26 listed removals and no additions; the plain sweep confirmed
1,203 entries at the new threshold. Deliberately calling each removed entry
under verify mode aborted with its expected method name.

The unused compiled-core reduction was checked on `94de5d14e`. Plain and verify
builds passed the same scenarios and all 543 maps. Runtime enumeration found
exactly the 75 listed compiled entries removed and no additions; the plain
sweep confirmed 1,128 entries at the new threshold. Forced lookups of all 75
removed entries aborted with their expected method names under verify mode.
