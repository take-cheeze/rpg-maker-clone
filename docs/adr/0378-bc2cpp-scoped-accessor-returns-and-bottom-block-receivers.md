# 0378. bc2cpp: scoped attr_reader results, and a literal-block send on a not-yet-classed receiver waits

Date: 2026-10-09

## Status

Accepted

## Context

The request: give the roughly 96 by-name sends whose receiver is an `attr_reader` result (`actors`, `teleport_targets`,
`items`, `charset_name`, `level`, ...) a proven return class from the closed-world ivar types, and restore the
RETURN_CLASS_TABLE entry of `skill_stat_mod_keys`. Measured on master `2c239f5f` (wio closed world,
`scripts/bc2cpp_send_root_report.rb`), the sites are 27 `actors`, 14+4 `teleport_targets`, 9 `items`, 5 `seg_lines`,
5 `charset_name`, 4 `screen`, 4 `level` and about 25 more names, each `candidate_dropped:<owner>[attr]`.

The reader itself is already modelled (ADR 0309). What drops these names is the slot's pool, and the pool's blocker is
never the reader:

| cause of the failed pool | examples |
| --- | --- |
| a constructor argument (`@actor = actor`, `@states = states`, `@parent = parent`) | `Combatant`, `Scene::Base` (ADR 0313, optional parameters) |
| `.map` / `.select` on a receiver of unknown class (`@actors = new_order.map { ... }`) | `Party#reorder` |
| an Integer or Float result (`@level = level && level >= 1 ? level : 1`) | no class bit exists for them |
| a literal-block send whose receiver is a not-yet-classed name or the slot itself | `@states = @states.select { ... }`, `FLAGS.keys.select { ... }` |

Only the last is a defect of the flow rather than a missing proof.

## Decision

### 1. BOTTOM_BLOCK_RECEIVER (the fix that changes the shipped C++)

The growth loop starts every tracked name at mask 0. A `SENDB` (a send with a literal block) on a receiver whose mask is
0 answered OTHER, so the name that contained it was dropped, and a dropped name never returns to the table. Every other
send of a tracked name answers its own mask (0 at first). A `SENDB` now answers 0 while the table is being built
(`@rc_scoped_ready` false) and the receiver is 0, so the loop re-runs it when the receiver grows. After the loop the
answer is OTHER as before, a name stuck at 0 stays unproven. The flow is monotone: 0 maps to 0, ARR to the core result,
OTHER to OTHER. Kill switch `BC2CPP_BOTTOM_BLOCK_RECEIVERS=0`.

`skill_stat_mod_keys` (`SKILL_STAT_MOD_FLAGS.keys.select { ... }`) returns Array again, along with `battle_items`,
`draw_stat_row`, `equip_candidates`, `field_items`, `learn_level_skills`, `log_round`, `step_vehicle_routes` (Array) and
`update_pictures` (Hash); `RPG2k::Scene::Base#@items` is `ARR|NIL`.

### 2. SCOPED_ACCESSOR_RETURN (a rule that ships no change today)

An exact receiver class that selects one `attr_reader` (`closed_world_exact_target(name, klass, accessor: true)`, which
keeps every installed-name, devirt-blocked and singleton check) answers that slot's class set
(`return_class_accessor_mask`), even when the name has another unmodelled definition elsewhere and so is not in the
name-wide table. It reads the same pool GETIV reads and the nil bit of an unassigned slot, so it claims nothing the
table would not. Kill switch `BC2CPP_SCOPED_ACCESSOR_RETURNS=0`.

It changes no generated C++ of the wio build (shipped C++ identical with it off and on): every accessor name in the
list above fails at its pool, not at the name. It is kept because the fixtures show names it would help (two classes
with a reader of one name, a subclass overriding the reader) and it is the one place the exact-receiver flow reads
a pool; ADR 0377 admits a sound, small change on its checks. Remove it if a later census still shows no site.

## Not claimed

* No class is claimed for a slot whose pool failed. A pool is not widened to a writer, a constructor argument, an
  `instance_variable_set` or a `define_method` target; the checks list each.
* A bottom receiver is not an unknown one: after the loop, a receiver still at 0 answers OTHER (scoped flow unchanged).

## Measurement

Same base, kill switches off against on, `SKIP_UNSUPPORTED=1`, `/*SO:*/` stripped (`scripts/bc2cpp_coverage_report.rb`):
`bc2cpp_send(` 2,086 to 2,082, `mrb_funcall*` 416 to 415, `CLOSED_WORLD_NATIVE_EXACT` arms 218 to 226. Six functions
change by-name counts (`Party#automatic_battle_placement?`, `ItemMenu#build_item_window`, `#item_col_x`, `#item_row_count`,
`#leave_target_mode`, `#move_item_cursor`); `build_item_window` gains sends because an `each_with_index` over a now-proven
Array inlines as a loop (its block body leaves a separate cfunc). The scoped rule alone: 0.

## Checks

`scripts/bc2cpp_call_results_check.rb` (section 1b: two classes with a reader of one name, an inherited reader, a writer,
a store of a second class, a store from a subclass, `instance_variable_set`, `define_method`, a singleton reader, an
override, an unassigned slot, both kill switches, the open world) and `scripts/bc2cpp_core_ruby_results_check.rb`
(`keys.select`, `@sl = @sl.select`, a `keys` override, a store of another class, the kill switch).
