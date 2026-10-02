# 0308. bc2cpp: a block reads the exact class of a captured local (CAPTURED_LOCAL_CLASS)

Date: 2026-10-02

## Status

Accepted

## Context

The request: increase direct-call coverage in the compiled rpg2k gem for the census categories
`core_tag_chain_else:receiver_other` and `core_tag_chain_else:receiver_is_ivar` (a call such as `empty?`, `size`,
`[]`, `push`, `include?`, `first` on an Array, Hash or String whose class is not proven, so the site keeps a
class-tag chain with a by-name else). The brief asked for the highest-yield *sound* slice of mutable-container class
tracking: an ivar or local whose every writer is known and always yields one core class, built on the class pools of
ADR 0296 (ivar pools, `INDEX_EXACT`, `NILABLE_RECEIVER`), not on element classes (ADR 0296 explains why those are not
provable).

### Measurement

Wio closed world, `scripts/bc2cpp_coverage_report.rb` shipped pass plus `scripts/bc2cpp_dynamic_site_census.rb`, master
`e1c671e4` (generator identical to `247a34e4`). Only functions whose name starts with `RPG2k` or `Game` are counted as
"rpg2k". Counting the census sends alone hides the index helpers, so the totals below also give the sites that can reach
by-name dispatch the way `docs/bc2cpp-dynamic-site-census.md` counts them (`bc2cpp_send` plus callers of
`bc2cpp_getidx`/`getidx0`/`setidx`/`slow_*`/`eqq`; the 328 block funcalls do not move).

| rpg2k, master | sites |
| --- | ---: |
| `core_tag_chain_else:receiver_other` | 714 |
| `core_tag_chain_else:receiver_is_ivar` | 204 |
| by name (both): `empty?` 207, `size` 158, `to_s` 140, `[]` 96, `push` 69, `length` 57, `to_i` 45, `[]=` 24, `include?` 23, `first` 20, `pop` 16, `keys` 15 | 918 |
| sites that can reach by-name dispatch (sends 2,205, getidx 2,034, setidx 225, slow 3,057, eqq 104) | 7,625 |

A temporary hook at `compile_insn` printed, for each of these sites, the exact-class flow's mask for the receiver
register and its reaching definitions (the hook is not committed). The producer of the receiver register, 913 sites
with a flow context:

| producer of the receiver | sites |
| --- | ---: |
| `@ivar` read (`GETIV`) | 214 |
| result of a call: `SEND0` 130, `SSEND0` 63, `SENDB` 31, `SSEND` 23, `SEND` 12, `AREF` 10 | 269 |
| `GETIDX` element of another container (ADR 0296: not provable) | 124 (+28 joined with a literal) |
| incoming argument (`ENTRY`) | 90 |
| reaching definitions refused (`UNPROVEN`: handler edges, state cap) | 67 |
| captured local (`GETUPVAR`) | 41 |
| constant (`GETCONST`/`GETMCNST`) | 34 |
| the rest (literals joined with a call, arithmetic, `KARG`) | 74 |

Only 20 of the 913 had a proven exact class and still kept the chain: 19 are `push` (`ARRAY_PUSH` has no exact arm).

### Why the ivars are not already pooled

For the 215 sites whose receiver is an `@ivar` read (the 214 above and one joined with a literal) the flow reports, per
ivar, the stores that keep it out of the pool, at the final state of the fixpoint:

| why the ivar has no usable pool | sites | examples |
| --- | ---: | --- |
| the stored value is a constructor or setter argument | 47 | `Scene::Base#initialize @parent = parent` 26, `MoveRoute#initialize` 7, `State#set_parallax` 7, `Battle#initialize` 7 |
| the stored value is `compact`/`map`/`select`/`reject`/`uniq`/`dup`/`sort`/`Array.new` of a receiver that is itself unknown | 63 (+29 more sites read it through `Party#actors`) | `Party @actors`, `Interpreter @call_stack`, `Actor @states` |
| a user method result that is itself unproven (also with the row above) | 14 | `Actor @equipment`, `Battle @queue` |
| an element of another container | 12 | `Party @items`, `ChipSet @terrain` |
| several of the above (an argument and an element) | 24 | `Interpreter @list` 22 |
| a numeric ivar that is not a container (`to_s` of a Float) | 8 | `Picture @red`, `Screen @r` |
| an `attr_writer`/`attr_accessor` writes it, or its name is a Symbol/String somewhere (`structural`) | 26 | `State @map_event_positions`, `CommonEventRecord @commands` |
| pooled exactly, but the consumer has no exact arm | 19 | `push` on `Interpreter @location_requests` |
| not in the report | 2 | |

There is no single reason. Each is a different missing proof, and most of them chain: the `map` receivers of the
second row are arguments or elements. An optimistic experiment (not shipped, unsound by construction) gave every
`compact`/`map`/`select`/`reject`/`uniq`/`sort`/`dup`/`to_a`/`keys`/`values` of an exact Array or Hash an exact result:
`core_tag_chain_else` moved by 4 sites of 1,205, because the receivers were unknown. The same experiment for
`Array.new`/`Hash.new`/`String.new` results moved the category by 12 and added 34 `bc2cpp_send` relocations beside new
`INDEX_EXACT` Array arms; net 3 sites. Constructor arguments cannot be pooled soundly: any `x.new(...)` with a
non-constant receiver (131 remain in the census) may build any class, so `initialize` stays excluded (rule 5 of
`entry_arg_candidates`).

The one root the pools do cover in principle and the flow still read as unknown is the **captured local**: a block
reading a local of its enclosing method. `ExactOracle#upvar_mask` answered `OTHER` for every `GETUPVAR`, while the numeric
flow (ADR 0276, `numeric_upvar_mask`) has answered it since ADR 0276 for Integer/Float. The numeric flow's masks already carry
the Array/Hash/String bits, so the argument carries over unchanged.

## Decision

### CAPTURED_LOCAL_CLASS

`ExactOracle#upvar_mask` returns, for a `GETUPVAR` of register `i` at `level` blocks up, the class set of the
register in the defining frame: the exact-class flow's state at the `BLOCK`/`LAMBDA` that created the closure,
joined with every value that flow recorded as stored into that register afterwards (`NumericFlow.states`' `writes`,
kept per irep in `@rc_writes` and invalidated with the states). A register a nested block writes (`SETUPVAR`) stays
unknown. The pieces, in `tools/bc2cpp/codegen_captured_locals.rb`:

- **The class of a variable is not about aliases.** An Array local that is mutated through any alias is still an
  Array; only a store into *this register* can change the class. That is why this needs no points-to information and
  does not contradict ADR 0296's refusal of element classes.
- **Stores into the register**: every instruction of the defining irep (the flow), every `SETUPVAR` of a nested
  block (excluded by `fixnum_proof_ctx(...)[:upvars]` and, independently, by the flow reading such a register as
  `OTHER`), and a write by name: `Binding#local_variable_set`, `eval`, a string `class_eval`/`module_eval` and the
  like. The closed-world builds (`psp`, `wio`, `maix`) refuse `mruby-eval`, `mruby-binding` and `mruby-proc-binding`
  (`BC2CPP_OPEN_WORLD_GEMS`), so no native of such a build can do it; `captured_local_writers_absent?` re-checks that
  instead of assuming it, and turns the proof off when any send, symbol or string of the world names one, when an
  outside Ruby source spells one, or when a native source of the *build* (the closed world's own outside natives, so an
  unlinked gem does not count) implements or calls one.
- **Everything the exact-class flow needs holds**: `ClosedWorld#exact_instances_singleton_free?` for the class bits,
  the world refusal, the closed world itself (the proof is off in an open world).
- **Consumers are unchanged.** A captured local with one class feeds `exact_core_value_class` (so `size`/`empty?`/
  `first`/`keys` take the exact arm, `INDEX_EXACT` drops the class test of `h[k]`/`h[k] = v`), `NILABLE_RECEIVER`
  (outside inlined loops, see below), and the numeric flow's native result facts.
- `BC2CPP_CAPTURED_LOCAL_CLASS=0` turns it off; the other class-pool switches are independent of it.

### What was measured and not built

| candidate | measured | decision |
| --- | --- | --- |
| result classes of core container methods on exact receivers | optimistic upper bound -4 of 1,205 (receivers unknown) | not built |
| `Array.new`/`Hash.new`/`String.new` result classes | net -3 reach sites; the rest relocates into `INDEX_EXACT` Array else arms | not built |
| constructor argument pools | blocked by non-constant `new` receivers | not built |
| `attr_writer` argument as a store of the ivar | 21 sites; needs the call-site join of every `x.name = v` and the name poisoning of ADR 0295 | not built |
| exact arm for `ARRAY_PUSH` | 20 rpg2k sites (19 on ivars) | its own change |
| `EXT1`/`EXT2`/`EXT3` as no-op prefixes in the analyses | 154 of 225 constant pools dropped because their class body has an `EXT2`; +138 constant pools, 19 reach sites | its own change |

## Consequences

Measured on the wio closed world, master `e1c671e4` against this change, same method and mruby (`mrbc` of the
repository's pinned `3rd/mruby`):

| rpg2k only | before | after | delta |
| --- | ---: | ---: | ---: |
| `core_tag_chain_else:receiver_other` | 714 | 707 | -7 |
| `core_tag_chain_else:receiver_is_ivar` | 204 | 204 | 0 |
| `bc2cpp_send` in bodies | 2,205 | 2,199 | -6 |
| `bc2cpp_getidx`/`getidx0` callers | 2,034 | 2,015 | -19 |
| `bc2cpp_setidx` callers | 225 | 194 | -31 |
| `bc2cpp_slow_*` callers | 3,057 | 3,046 | -11 |
| **sites that can reach by-name dispatch** | **7,625** | **7,558** | **-67 (-0.9%)** |

All gems: 9,536 to 9,468 (-68). The rpg2k number is where the change lands; `LCF`/`RGSS` move by one.

Removal versus relocation, counted in the generated code: 41 more `INDEX_EXACT` Hash arms (no else arm, a removal),
9 more `INDEX_EXACT` Array arms (an Integer fast path whose else is a by-name `[]`/`[]=`: the helper call became an
inline send, a **relocation**, already netted out of the -67 because the added `bc2cpp_send` is in the `sends` row),
4 more registered exact arms, 11 fewer slow-path helper calls (an RGSS native result such as `bitmap.width` of a captured
exact `Bitmap` is now Integer for the numeric flow). So the gain is mostly `h[k] = v` and `h[k]` on hashes built before a
block and used in it; it is **not** the `empty?`/`size` chains the request names (-7 of 918, 0.8%), and it does nothing for
`@ivar` receivers. The ivar category needs the per-reason proofs in the table above; none of them is as large as the
population the census named, and the argument-shaped ones are blocked by the open `new`.

`NILABLE_RECEIVER` is skipped for a send inside an inlined loop (`trace_reg_offset` is not zero there), so a captured
`nil`-or-Array local keeps its guarded chain in `3.times { }`; the fixture covers the behaviour (NoMethodError on nil)
but cannot show a positive arm.

### Withdrawal conditions

| condition | what withdraws | negative case |
| --- | --- | --- |
| `binding`, `local_variable_set`, `eval` in a send, symbol or string of the world | every captured-local class | `a binding`, `a local_variable_set`, `an eval`, `a binding named by a symbol` |
| a string `class_eval`/`module_eval`/`instance_eval` (no literal block) | every captured-local class | `a string class_eval` (and `a class_eval with a literal block` does not) |
| a native or outside Ruby source of the build spelling one of those names | every captured-local class | `a build gem with a native ...`, `a build gem whose mrblib spells binding` (an unrelated gem does not) |
| a singleton maker, `global_refusal` | every exact proof (ADR 0280) | `a singleton maker` |
| the local is an argument, assigned two classes, assigned in a block, assigned by a sibling block, a block parameter, a call result | that local | `cap_arg`, `cap_mixed`, `cap_block_write`, `cap_sibling_write`, `cap_block_param`, `cap_unknown_call`, `cap_late` |
| `BC2CPP_CAPTURED_LOCAL_CLASS=0`, open world | everything | kill switch, open-world cases |

One guard has no killing world and so no mutant: the explicit nested-write test (the flow itself reads a register a nested
block writes as `OTHER`, so the test stays as defence in depth, as `numeric_upvar_mask` keeps it). The join of later
writes does have one: a confined lambda (`line = ->(n) { acc.size + n }` then `line.call(k)`, CONFINED_LAMBDA_UPVAR_SUPPORT)
is called after the frame stored another class into `acc`, and `cap_lambda_late` fails without the join. A block that
captures a local is outlined only for a method that runs it synchronously (`BLOCK_FALLBACK_UPVAR_SAFE_METHODS`) or as
such a lambda, so no closure outlives its frame.

### Residual risk

- The arms are unchecked: a wrong exact class is a crash or wrong answer, not a logged violation (ADR 0296's list).
  The writer specific to this proof, a local written by name, needs `mruby-eval`/`mruby-binding`, which a closed-world
  build refuses and the gate looks for again; a new way to write a frame's register from native code would not be seen.
- Fibers: a block that may suspend a Fiber keeps its frame alive; ADR 0283 keeps those methods interpreted or
  resumable, and the flow reads the register through the same states either way.
- The 32-bit `mrb_int` run leaves out `cap_nested` and the two lambda methods: a block outlined inside another block
  and a confined lambda run through `bc2cpp_block_thunk`, which crashes in a 64-bit host built with
  `-DMRB_32BIT -DMRB_INT32`, on master too (the same `2.times { 2.times { } }` fails without this change). No mask or
  constant here reaches an `mrb_int`.
- Firmware smokes (psp, wio, maix) and CI were not run.

## Tests

`scripts/bc2cpp_captured_local_class_check.rb`: generated code (eight positives, nine negatives, nine withdrawal
worlds, the class_eval/unrelated-gem controls, both kill switches, the open world); compiled against interpreted on a
full-core and a core-only mruby, and on a 32-bit `mrb_int` build, including a block that reassigns the local, a
sibling block that does, a lambda called after the local changed class, a nil-then-Array local and a frozen Array.
`scripts/bc2cpp_captured_local_class_mutation_check.rb`: eight mutants of the soundness conditions. `scripts/bc2cpp_fixture_runtime.rb` gained `build_gems:` so a fixture can add a
gem (its `src/` and `mrblib/`) to the closed-world build. Wired into its own `captured-locals` shard of
`bc2cpp-checks`.
