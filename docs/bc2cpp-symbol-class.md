# bc2cpp: the Symbol class bit of frozen tables (ADR 0424)

A `LOADSYM` element of a frozen literal Array or Hash (`[:a, :b].freeze`) is a Symbol. Its slot is now the Symbol
class bit (`CodeGen#frozen_symbol_bit`, the same `numeric_class_bit('Symbol')` the exact-class run gives LOADSYM
literals), so `TABLE[i]` reads SYM (or SYM|NIL) in the numeric class flow instead of OTHER.

Code: `tools/bc2cpp/codegen_frozen_tables.rb` (slot reader, switch), `tools/bc2cpp/frozen_tables.rb` (naming),
`tools/bc2cpp/codegen_numeric_proof.rb` (`numeric_mask_name`), `tools/bc2cpp/numeric_flow.rb` (header).
Kill switch: `BC2CPP_SYMBOL_CLASS=0` (also off when `BC2CPP_IMMEDIATE_CLASS_BITS=0`). Check:
`scripts/bc2cpp/symbol_class_check.rb`. A `LOADSYM` register carries the same bit in the numeric flow (ADR 0428, the
section below), with kill switch `BC2CPP_LOADSYM_CLASS=0` and check `scripts/bc2cpp/loadsym_class_check.rb`.

## Consumers audited

The bit reaches the numeric masks only through FrozenTables reads (`index_mask`, `first`/`last`/`sample`). The exact-class
run (`ExactOracle`) has no such reads and never reads a numeric mask, so it cannot see the bit.

| Consumer | Behaviour with a SYM bit | Result |
| --- | --- | --- |
| `NumericFlow.arith` | non-numeric operand gives OTHER | refused |
| `narrow_by_truth` / `falsy_class_bits` | a Symbol is truthy: dropped on the falsy edge | sound |
| `numeric?`, `containers?`, `== NumericFlow::INT` (native direct, step loop, native-result check) | not equal to INT | refused |
| `OPAQUE` filters (numeric args, consts, ivars, roots) | SYM is in OPAQUE | refused across methods |
| `numeric_send_mask` owner table | SYM not an owner: OTHER | refused |
| `frozen_table_send_mask` / `end_read` | slot classes returned | SYM kept (same-frame value) |
| `@numeric_return` (NUMRET) | a method returning a Symbol slot | SYM crosses by return value (ADR 0289 rule); callers take it as a class bit |
| `numeric_upvar_mask` (captured locals) | same-frame union of writes | SYM kept |
| `tuple_position_mask` | only NUM and NIL survive | OTHER |
| LCF `index` / `lcf_exact_receiver` / `exact_owner` | foreign bits OTHER; exact single kind only | refused |
| `core_ruby_results`, loop regions core-bit subsets | not a core class | refused |
| `frozen_table_exact_class` | subset of the table bits required | refused |
| Class narrowing (`class_test_verdict`) | `is_a?` from the closed-world chain; `respond_to?` unnamed; membership needs a declared class and uses `mrb_obj_class` | sound |
| Entry specialization (`!mrb_immediate_p`), immediate native guards | exact-class run only | not reached |
| Setter pools, escape, instance receivers, return classes | exact-class run only | not reached |
| `numeric_mask_name`, FrozenTables and roots reports | names only | diagnostic |

## Measurement

Tree: this branch, with the origin/master copy as the baseline (`git archive`), both with the mruby sources of the main
checkout linked in (the worktree's `3rd/mruby` is an empty submodule). Command:
`MRBC=3rd/mruby/build/host/bin/mrbc BC2CPP_COVERAGE_KEEP_DIR=... ruby scripts/bc2cpp/coverage_report.rb`.

| Run | shipped.cxx | shipped.stderr | report |
| --- | --- | --- | --- |
| origin/master (baseline) | 21,005,028 bytes | 1,374,515 bytes | 10,928 bytes |
| this branch, `BC2CPP_SYMBOL_CLASS=0` | identical to baseline | identical | identical |
| this branch, default | identical to kill switch off | 23 lines removed, 25 added | identical |

Facts-report differences with the bit on (kill switch off in brackets):

* 14 `NUMCONST` groups change from `OTHER` to `SYM` (for example `STAT_NAMES`, `EQUIP_ORDER`, `TYPES`, `KEY_INPUT_GROUPS`,
  `RPG2K_EXTENSIONS`); one of them is `FROZEN:Array[NIL*2,SYM*4]` (`EQUIP_BONUS_FIELD`).
* Frozen-table shapes: 49 to 51 (two new Symbol shapes); 8 existing shape names change `OTHER` to `SYM`.
* No emitted C++ changes: 0 bytes differ in the generated code. The bit reaches the masks, and no emitter currently
  decides on a Symbol mask, so the gain is in the flow's knowledge only.

`DebugMenu::MODES` (`mruby-rpg2k/mrblib/scene/debug_menu.rb`) is a Symbol table, but its reads (`MODES.index`,
`MODES[idx]` with `idx` from `%`) feed no numeric fact, so it has no `NUMCONST` line and does not change.

## Checks run

* `scripts/bc2cpp/symbol_class_check.rb` (host model, and with `MRBC` the generated half: facts names, kill switch, a
  `"x".to_sym` slot staying OTHER, a redefined `Array#freeze`, a `const_missing`): PASS.
* `frozen_tables_check.rb` (`FT_GENERATED_ONLY=1`): PASS, 91 ok, 0 FAIL.
* `numeric_operand_check.rb` (with `MRBC`): PASS, 89 ok. Host-only: `lcf_row_flow_check`, `tuple_return_check`,
  `register_flow_check`, `join_dominance_check`, `core_mixins_check`, `typed_reflection_check`,
  `native_result_facts_check`, `class_object_args_check`, `literal_element_check` (with proof on and off): PASS.

Not run: `frozen_tables_mutation_check.rb`, `numeric_native_direct_check.rb`, `literal_element_mutation_check.rb`
and the behavioural halves (g++ on a full mruby build). The corpus run covers the generated code of every shipped
method.

## LOADSYM registers (ADR 0428)

A `LOADSYM` in a register is the Symbol bit in the numeric flow too (`NumericOracle#literal_class_mask`, the bit of
`frozen_symbol_bit`). Its consumers, by where the mask goes (`BC2CPP_LOADSYM_CLASS=0` restores OTHER):

| Consumer | Behaviour with a SYM bit | Result |
| --- | --- | --- |
| Register copies (`MOVE`, copy provenance) | the value is an immediate copied as is | sound |
| Same-frame upvars (`numeric_upvar_mask`, captured locals) | the block reads the same immediate | sound |
| Arguments (`numeric_entry_mask`, `codegen_numeric_args.rb`) | OPAQUE filter: the pooled argument is refused | refused |
| Ivars (`codegen_numeric_ivars.rb`, `ivar_fact_mask`) | OPAQUE filter: the ivar group is refused | refused |
| Constants (`codegen_numeric_consts.rb`) | OPAQUE filter: the constant group is refused | refused |
| Returns (`@numeric_return`, NUMRET) | the method result is SYM; callers take the bit from the return value (ADR 0289 rule) | sound, the same route as a frozen-table Symbol |
| `numeric_send_mask` with a SYM receiver | `recv & ~owners` keeps SYM: OTHER, as before the change | refused |
| `numeric_send_mask` tables / `frozen_table_send_mask` | only shape bits reach the table reads | sound |
| Native results (`native_result_numeric_mask`) | read the exact-class receiver (already carries SYM for a LOADSYM receiver) | unchanged |
| Comparisons (`EQ`, `LT`/`GT` silent sends, `numeric_operator_fallback`) | EQ and silent sends are OTHER; the arm needs `numeric?` | refused |
| Arithmetic (`arith`, `ADD`/`SUB`/`MUL`/`DIV`, `ADDI`) | a non-numeric operand gives OTHER | refused |
| `numeric?`, `== INT` (native direct, step loop, `frozen_table_exact_class`) | SYM is not INT; the frozen-table subset fails | refused |
| Truthiness (`narrow_by_truth`) | a Symbol is truthy: dropped on the falsy edge | sound |
| Class narrowing verdict (`class_test_verdict`, `class_test_chain`) | the Symbol chain is `[Symbol]`: exact verdict for every admitted test name | sound (ADR 0428) |
| Class narrowing claims (`class_narrowing_membership`) | a SYM membership needs a declared `Symbol` class (none): no claim on a dropped SYM | sound |
| Class narrowing positive (`class_test_positive`) | Symbol is bitless: no positive class, OTHER stays OTHER | sound |
| `respond_to?` (`class_test_responds_verdict`) | Symbol is not in CLASS_TEST_CORE_CHAIN: unknown, both edges | sound |
| Frozen-table reads (`element_index_mask`, `frozen_table_other_index`) | key `== INT` fails (as OTHER did); `lcf_bits(SYM)` is zero: OTHER | sound |
| LCF (`lcf_index_mask`, `lcf_exact_receiver`, `exact_owner`) | foreign bit: OTHER; `exact_owner` only for object-kind bits | refused |
| Tuple returns (`tuple_position_mask`) | `TUPLE_KEPT_BITS` is NUM\|NIL: OTHER | refused |
| Exact-class consumers (`exact_flow_mask`: instance receivers, escape, nilable receiver, loop regions, setter pools, native send unions) | the exact flow never reads a numeric mask (checked by grep); its class narrowing now decides the bit | unchanged inputs; sound as above |
| `LiteralElementProof`, `CallFacts`, core-results and profiler oracles | their own oracles or instruction scans: no literal class mask | unchanged |
| Diagnostics (`numeric_mask_name`, NUMRET/NUMARG reports, roots) | names only | diagnostic |

Class narrowing on a LOADSYM literal (the exact-class run) also decides the Symbol bit now, so `:a.is_a?(Integer)` has an
empty truth edge and `x.is_a?(Symbol)` on `SYM|NIL` keeps nil on the falsy edge. Each such test is claimed by a
CLASS_NARROWING guard that the closed world checks at run time.

### Measurement (ADR 0428)

Trees: origin/master (`git archive`, baseline) and this branch, both with the main checkout's mruby sources linked in.
Command: `LANG=C.UTF-8 MRBC=3rd/mruby/build/host/bin/mrbc BC2CPP_COVERAGE_KEEP_DIR=... ruby scripts/bc2cpp/coverage_report.rb`.

| Run | shipped.cxx | shipped.stderr | report |
| --- | --- | --- | --- |
| origin/master (baseline) | 21,128,326 bytes | 1,322,765 bytes | 10,914 bytes |
| this branch, `BC2CPP_LOADSYM_CLASS=0` | identical to baseline | identical | identical |
| this branch, default | identical to baseline (0 bytes differ) | +10 lines, +312 bytes | 1 line differs |

Facts-report differences with the bit on: ten `NUMRET` lines appear, one per method that returns a Symbol (or a value
that may be a Symbol): `NUMRET` `anim_input` (NIL|SYM), `battle_skill_target` (SYM), `battle_start_field` (NIL|SYM),
`block` (NIL|SYM), `end_round` (NIL|SYM), `enter_battle_result` (SYM), `note_anim_input` (NIL|SYM), `side_of` (SYM),
`stat_mode` (SYM), `try_battle_escape` (INT|SYM). The report's "method names returning" count goes from 388 to 398.
No emitted C++ changes in the corpus: the shipped output of the whole game is byte-identical with the bit on.

Per-function output changes: none in the shipped corpus. Small fixtures do change (checked by hand, not in the corpus):
a Symbol-or-Integer value narrowed by `is_a?(Integer)` gets a CLASS_NARROWING guard on each edge (the guard checks the
claim the narrowing makes and never fires for a correct flow), and a literal Symbol tested by `is_a?(Integer)` gets a
guard on its empty truth edge. Before the one-class chain was added, the same fixture lost the numeric arm of its
Integer branch (a precision regression: the unknown Symbol kept both edges); the chain restores it.

## Checks run (ADR 0428)

* `scripts/bc2cpp/loadsym_class_check.rb`: host model and generated half (MRBC): PASS.
* `symbol_class_check.rb` (MRBC): PASS. `frozen_tables_check.rb` (`FT_GENERATED_ONLY=1`), `numeric_operand_check.rb`,
  `literal_element_check.rb`, `class_narrowing_check.rb` and `class_narrowing_mutation_check.rb`,
  `frozen_tables_mutation_check.rb`, `numeric_native_direct_check.rb`: each fails on the same lines on origin/master
  in this environment (the g++ runtime halves are skipped here, and a few native-source cases need the linked
  runtime). The candidate's failing set equals the baseline's for every one of them.
* Host-only checks (`frozen_slot`, `lcf_row_flow`, `tuple_return`, `register_flow`, `join_dominance`, `core_mixins`,
  `typed_reflection`, `native_result_facts`, `class_object_args`, `literal_element_mutation`): PASS.

## Not done

* A frozen table refused for another reason allocates no Symbol bit, so a `LOADSYM` register stays OTHER there.
* `LiteralElementProof` gives a Symbol element of a non-frozen literal OTHER. TrueClass and FalseClass literals stay
  OTHER in the numeric flow.
