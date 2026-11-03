# Collection intermediates in bc2cpp analysis

Several bc2cpp analyses built an Array, Set or Hash snapshot only to iterate
it, test it or throw it away. Each one was small, but the methods holding
them run once per instruction of a fixpoint, once per send site or once per
dataflow step, so together they were a visible share of the host objects the
compiler allocates. This page lists what changed and how it was measured.

## How the sites were found

An object-mode profile of the sealed Optcarrot compile
(`scripts/bc2cpp/compiler_profile.rb --mode object --optcarrot`, see
[compiler data profiling](bc2cpp-compiler-data-profile.md)) was recorded with
stackprof's `raw: true`, and every self sample of `Array#map`, `Array#+`,
`Array#uniq`, `Array.new`, `Kernel#dup`, `Hash#to_a`, `Set#to_a`,
`NilClass#to_a` and `Enumerable#filter_map` was attributed to the nearest
`tools/bc2cpp` frame on its stack. The hottest callers in files this change may
touch were (samples at the 1-in-100 object interval, 110,009 in all):

| Caller | Leaf | Samples |
| --- | --- | ---: |
| `CodeGen#slot_assigns_on_exit_uncached?` | `Array#map` | 1,848 |
| `CodeGen#receiver_instances` | `Hash#to_a` | 1,002 |
| `NativeCoreDirect.audit` | `Array#+`, `NilClass#to_a`, `flat_map`, `map` | about 900 |
| `Set#to_a` from `case ... when *SET` (`ClosedWorld`, `IrSymbolFlow`, ...) | `Set#to_a` | 761 |
| `CodeGen#method_resolution_owners` | `NilClass#to_a`, `Kernel#dup`, array literals | about 430 |
| `RegisterFlow#build_edges` | `Array#+`, `Array#uniq`, `Array.new` | about 350 |
| `CodeGen#numeric_assigned_before_exposure?` | `Array#map` | 208 |
| `CodeGen#nested_ireps` | `Enumerable#filter_map` | 96 |

## What changed

- **Fixpoint meets.** `slot_assigns_on_exit_uncached?` (ivar_slot_assured.rb)
  and `numeric_assigned_before_exposure?` (codegen_numeric_ivars.rb) built an
  Array of predecessor states per instruction per round and asked
  `empty? || all?`. They now ask `all?` with a block over the predecessor
  list, which is the same Boolean without the Array. The handler-predecessor
  table is a plain Hash read without auto-vivifying an empty Array for every
  instruction.
- **`receiver_instances`** iterates `@numeric_class_bits` directly instead of
  its `to_a` copy; the loop does not add classes to the table.
- **`case ... when *SET`.** A splatted Set in a `when` clause calls `Set#to_a`
  every time the `case` runs. `Set#===` is `include?`, so `when SET` matches
  the same values without the Array. Changed for the `BytecodeIR::Ops` Sets
  and the local Set constants in closed_world.rb, ir_symbol_flow.rb,
  escape_analysis.rb, record_hash.rb, block_self_world.rb,
  unique_class_names.rb, rbs_param_check.rb, rbs_record_types.rb,
  element_layouts.rb and declared_constants.rb. `when *ARRAY` is left as it is:
  splatting an Array does not copy it.
- **`NativeCoreDirect.audit`** rebuilt the concatenation of every entry list
  and its header names on each call. Both are now constants
  (`AUDITED_ENTRIES`, `AUDITED_HEADERS`) computed when the file loads; the
  per-call stat key of the audited files is unchanged, so the cache still
  notices an edited source. `mruby_include_dir` stops at the first matching
  path instead of mapping all of them.
- **`method_resolution_owners`** walked a separate queue built from
  `[superclass, *Array(included), *Array(prepended)]` per owner. The queue was
  always the unvisited tail of the result, so it now walks the result by index
  and reads the mixin lists in place (they are Arrays or nil).
- **`RegisterFlow#build_edges`** shares one frozen empty list for the handler
  successors of a method without handlers, and skips the `normal + handler`
  copy when there are no handler edges. The lists are only read after they are
  built.
- **Smaller ones:** `deep_fiber_yield?` / `deep_called_names` yield nested
  ireps instead of collecting them (`each_nested_irep`), and
  `arm_prune_reachable` builds the unreached set directly instead of
  `(0...size).to_set - reached`.

Iteration order is unchanged everywhere: the replaced intermediates were
copies in the original order, and the index walk in
`method_resolution_owners` visits owners in the order the queue did.

## Measurements

Sealed Optcarrot compile, `scripts/bc2cpp/compiler_profile.rb --mode none
--optcarrot` (Ruby 4.0.5 with YJIT), one warm-up run and then three
alternating runs per version on the same host:

| Run | Version | `allocated_objects` | `elapsed_seconds` |
| --- | --- | ---: | ---: |
| 1 | master | 10,839,332 | 8.387 |
| 1 | this change | 10,216,019 | 8.577 |
| 2 | master | 10,839,370 | 8.443 |
| 2 | this change | 10,216,028 | 8.368 |
| 3 | master | 10,839,401 | 8.518 |
| 3 | this change | 10,215,998 | 8.092 |

Allocations fell by about 623,350 objects per run (5.8%), with a spread of
under 70 objects within each version. Elapsed time moved in both directions
and shows no consistent change, so no speedup is claimed.

The generated C++ and the compiler log of the two versions are identical once
the per-run temporary world path (plain and hex-escaped in string pools) is
normalized.

## Left alone

- `NumericFlow.step_transfer` / `copy_reg_write` `dup` a state only when they
  write to it; the copy is the result.
- `NativeCoreDirect.audit`, `ForeignDefiners.scan` and `OutsideRubyOwners.scan`
  still `File.stat` every file on every call to key their caches (about 2.4% of
  samples together). Skipping that would change when an edited source is
  noticed, so it is not part of this change.
- Hot sites in files other open pull requests change (codegen_ivar_poly.rb,
  codegen_send.rb, dispatch_targets.rb, codegen_receiver_facts.rb, ...) and in
  the BytecodeIR / InsnDecoder files.
