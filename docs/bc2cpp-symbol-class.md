# bc2cpp: the Symbol class bit of frozen tables (ADR 0424)

A `LOADSYM` element of a frozen literal Array or Hash (`[:a, :b].freeze`) is a Symbol. Its slot is now the Symbol
class bit (`CodeGen#frozen_symbol_bit`, the same `numeric_class_bit('Symbol')` the exact-class run gives LOADSYM
literals), so `TABLE[i]` reads SYM (or SYM|NIL) in the numeric class flow instead of OTHER.

Code: `tools/bc2cpp/codegen_frozen_tables.rb` (slot reader, switch), `tools/bc2cpp/frozen_tables.rb` (naming),
`tools/bc2cpp/codegen_numeric_proof.rb` (`numeric_mask_name`), `tools/bc2cpp/numeric_flow.rb` (header).
Kill switch: `BC2CPP_SYMBOL_CLASS=0` (also off when `BC2CPP_IMMEDIATE_CLASS_BITS=0`). Check:
`scripts/bc2cpp/symbol_class_check.rb`.

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

## Not done

* A `LOADSYM` in a register outside a table is still OTHER in the numeric flow (the numeric oracle has no literal class
  mask). It would need its own audit.
