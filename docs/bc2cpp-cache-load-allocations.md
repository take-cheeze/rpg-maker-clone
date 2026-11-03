# Scan-cache loads and state copies in the bc2cpp compiler

Two frames led the object profile of the sealed Optcarrot compile once the
per-file scan caches had landed: `Marshal.load` in `ScanCache.load_entry`, and
`Kernel#dup` / `Array#initialize_copy`. Both are C functions, so a flat
profile hides who calls them. This page records where they come from, the one
change that was made, and what was measured and left alone.

All numbers are from `scripts/bc2cpp/compiler_profile.rb --optcarrot` on
Ruby 4.0.5 with YJIT. Callers were attributed at `8b208c5cc` with
`StackProf.run(mode: :object, raw: true)`, by walking each raw stack to the
nearest `tools/bc2cpp` frame. The final comparison is against `82b93ceff`,
which also contains #3103 and #3105.

## `Marshal.load` in `ScanCache.load_entry`

A logging wrapper around `load_entry` counted these loads in one warm run:

| | Count |
| --- | ---: |
| `load_entry` calls | 666 |
| distinct entry files | 594 |
| loads of an entry already loaded or stored by the same process | 72 |
| objects allocated inside `load_entry` | 141,586 |

A load allocates about one object for each String, Array, Hash or Set in the
stored value. The largest groups are:

| Scan | Loads | Distinct | Objects |
| --- | ---: | ---: | ---: |
| `outside_world_tokens.file` | 142 | 142 | 52,757 |
| `closed_world.native_file` | 103 | 103 | 32,210 |
| `outside_world_tokens` (whole list) | 3 | 1 | 28,671 |
| `native_owner_map.file` | 104 | 103 | 8,106 |
| `class_world.build` | 1 | 1 | 4,946 |
| `native_names.foreign_method_names` | 45 | 40 | 3,154 |
| `integer_constants.native_defined_const_names` | 10 | 1 | 2,611 |
| `native_direct.sibling_param_owners` | 46 | 3 | 773 |

**Repeated loads (changed).** `bc2cpp.rb` asked for `outside_world_tokens` of
the same paths three times: for the RBS constructor-site CodeGen, for
`RecordHash`, and for the main CodeGen. Under `--optcarrot` the first call
misses, because the list includes the per-run temporary world. It builds the
Set from the per-file entries and stores it. The second and third calls then
read back the entry the process had just written, about 9,500 Strings each
time. A normal game build hits the stored entry and loads it three times.

Every reader only calls `include?` on the Set: `CodeGen` (`codegen.rb`,
`codegen_class_pools.rb`, `codegen_fixnum_proof.rb`,
`codegen_numeric_roots.rb`, `codegen_return_classes.rb`,
`codegen_constructor_pools.rb`, `codegen_setter_pools.rb`,
`send_root_report.rb`) and `RecordHash::KeyPool`. Its inputs, `native_paths`
and `foreign_ruby_srcs`, are each assigned once and never changed in place.
`bc2cpp.rb` now keeps the first result in a local and passes it to the later
readers. The first call still happens at the same point in the run, so the
profile buckets and the missing-file warnings stay where they were.
`SourceText` prints each path once per process. `ScanCache` itself is
unchanged.

**Other repeated loads (left).** The other 70 repeated loads add up to about
4,300 objects (0.08%). They are spread over a dozen call sites in several
files. Removing them needs either a memo at each site or the existing
`ScanCache.memory` switch. That switch hands the same object to every caller,
so every reader of every scan would first have to be shown not to mutate it.

**Entry shape (left).** Most of the remaining objects are the Strings the
scans return, such as the identifier tokens of 142 sources. The readers need
those Strings, so another storage shape would allocate them anyway. A joined
String would only move the work into `split`. Bundling the small per-file
entries into one file would save only the per-entry `[magic, key, value]`
Array and its two Strings, about 2,000 objects in all. It would also lose what
the per-file entries were added for: a changed source rescans only itself.

**Entries that never hit (left).** The whole-list scans (`closed_world.native`,
`closed_world.ruby`, `outside_world_tokens`, `closed_world.broad_def_names`,
…) include the temporary Optcarrot world in their path list, and the path is
part of their key. Under `--optcarrot` they miss on every run and store a new
entry: 33 stores, 825 KB and 18 ms per run. That is why a long-used cache
directory holds thousands of entries. A normal game build, whose paths do not
change, hits them. The path stays in the key because a scan's result can
contain it.

## `Kernel#dup` and `Array#initialize_copy` (no change)

| Caller (nearest `tools/bc2cpp` frame) | `Kernel#dup` | `Array#initialize_copy` |
| --- | ---: | ---: |
| `NumericFlow.step_transfer` | 374 | 406 |
| `NumericFlow.copy_reg_write` | 386 | 382 |
| `NumericFlow.join_state` | 33 | 10 |
| `CallFacts::Flow.dup_state` | 90 | 69 |
| `RegisterFlow#build_edges` | 97 | 0 |
| `CodeGen#method_resolution_owners` | 64 | 0 |
| `CodeGen#compile_method` | 46 | 0 |
| `BytecodeIR::Program#forward_reachable` | 32 | 0 |
| others (each ≤ 26) | 112 | 2 |
| total samples (1 in 100 allocations, of 62,115) | 1,234 | 869 |

**The copies are needed.** `NumericFlow.states` keeps one state per
instruction (`ins`) and returns them all. The worklist compares each output
with the last one stored (`outs`), and successors share incoming states. A
transfer that changes a register therefore needs a new Array. The transfers
already return the input unchanged when nothing changes (`copy_reg_write`,
`unchanged_reg_write?`, `join_state`). `CallFacts::Flow` does the same with its
`[cls, facts]` pair, and `detach!`/`attach!` write both Arrays. The other
callers in the table copy a list that they then append to or write.

**The second object can be avoided, but at a cost.** `Array#initialize_copy`
allocates only when the source is heap-backed and not yet shared. It then
turns the source into a hidden shared root, a second object. A state made by
an earlier copy is heap-backed, so each copy along a chain of transfers costs
two objects:

| Copy of a heap-backed Array, then one write | n = 3 | n ≥ 10 |
| --- | ---: | ---: |
| `state.dup` | 1 | 2 |
| `[*state]` | 1 | 1 |
| `[].concat(state)` | 1 | 1 |

Both one-object forms were tried in `NumericFlow.copy_state` and
`CallFacts::Flow.dup_state`. Each produced byte-identical C++ and removed
`Array#initialize_copy` from the profile (869 samples to 1):

- `[*state]` (and likewise `Array.new(n)` or `state + []`) puts the copy in an
  embedded slot sized to the state, for example 320 bytes for 30 registers.
  The compile then ran 14 more GCs. Over 4 alternating runs, GC time rose
  from 779 to 1,093 ms and elapsed time from 6.93 to 7.26 s.
- `[].concat(state)` keeps the 40-byte slot and a malloc'ed buffer, as `dup`
  does after its first write. It saved 114,738 objects (2.19% at
  `82b93ceff`), with the same GC count, GC time and elapsed time over 15
  alternating runs. But `concat` grows the buffer to 16 elements past the
  state's length, and the states stay alive. That is about 88 bytes more per
  copy than the 40-byte root it saves. Mean peak RSS was 12 MB higher
  (274,601 to 286,871 KiB). The noise in RSS is large: the change below,
  which cannot use more memory, also measured 7 MB higher. Even so, the
  per-copy arithmetic says `concat` does raise memory.

No form gives a 40-byte slot with an exact-size buffer and no root. Fewer
objects did not buy GC or wall time, and the cost is more retained memory, so
the copies stay `dup`. The other `dup` callers are at most 0.17% of samples
each.

## Results

Generated C++ is byte-identical to the baseline after the per-run
temporary-world path is normalised, and so is the compiler's stderr. Warm runs
use one warm-up per version, then 5 alternating unsampled runs each. Cold
runs set the real cache directory aside, one pair per round.

| Warm, against `82b93ceff` | Baseline | Changed | Change |
| --- | ---: | ---: | ---: |
| allocated objects (mean) | 5,241,388 | 5,210,849 | −30,539 (−0.58%) |
| elapsed seconds (mean) | 6.273 | 6.247 | noise |
| GC milliseconds (mean) | 652 | 659 | noise |

| Cold, against `82b93ceff` | Baseline | Changed | Change |
| --- | ---: | ---: | ---: |
| allocated objects, round 1 | 6,779,149 | 6,748,722 | −30,427 (−0.45%) |
| allocated objects, round 2 | 6,779,011 | 6,748,583 | −30,428 (−0.45%) |

Objects allocated inside `load_entry` in a warm run went from 141,586 to
112,916, and `load_entry` calls from 666 to 664. The saving is the same warm
and cold because both runs miss the whole-list entry and then reload it. The
timing differences are within run-to-run noise, so this page claims no
speedup.
