# 0398. bc2cpp: a send in an inlined loop body takes its flow position

Date: 2026-10-10

## Status

Accepted

## Context

`closed_world_site` gets the instruction index `idx` of a send. A send inside an inlined `each`/`map`/`times`
body (`compile_insn` over the block's irep with registers shifted by `reg_offset`) has `idx` nil: the body's
own index is passed as `trace_idx` (ADR 0386 added `trace_insn` for `unlisted_class_call`). The flow-based gates
read `site[:idx]` and `site[:insn]`: `receiver_instances` (ADR 0302), `refined_receiver_instances` (the call
facts) and `nil_may_answer?`. With no position they return nil, so the receiver's class set is unproven and the
send stays by name with `singleton_definer`, `core_or_native` and the other reasons.

ADR 0384 measured the shipped pass of the wio closed world: nine `singleton_definer` sites, three of them the `wait`
sends in `RPG2k::Scene::Map#resolve_key_input`, whose receiver is a `KeyInputRequest` read from a method local
inside an inlined `each` body.

## Decision

**LOOP_FLOW_POSITION.** `closed_world_site` takes `trace_insn` and `trace_reg_offset` from the four call sites
that already pass `trace_idx`, and attaches `site[:flow]`, the flow position of the send, when `idx` is nil.
`loop_flow_position` decides it:

1. The send must be the shifted instruction of `irep.instructions[trace_idx]`: same address, op and symbol, and
   the receiver register equal after the shift. A synthetic send (address 0: a typed index or splat helper) and an
   SSEND (a self call, which needs no set) have no receiver position and are refused.
2. The receiver's definitions are the block irep's reaching definitions of the register (`follow_moves`), refused
   when the block's own opaque registers reach it.
3. **Element.** A definition that binds the loop element (R1 at ENTER or its entry value) makes the receiver the
   loop element. If the body writes R1 again, the position is refused (`element_reassigned`).
4. **Block-local.** Every definition is a non-upvar write of the block: the position is the block's own flow at
   the send (`site[:flow] = { irep: block_irep, idx: trace_idx, insn: original }`). A block activation starts from
   unknown inputs (`CallFacts::Flow.states`), and the inlined frame is reset every iteration (`inline_block_frame`),
   so the facts there hold for that iteration, exactly as the BLOCK_FALLBACK bodies already use them (idx passed).
5. **Method local (refused, `upvar_narrowed`).** Every definition is a GETUPVAR at level 0, which in an inlined body is
   the method register `upvar_idx` (`codegen_loop_regions`). This path would take the method's flow at the loop's own
   SENDB, but it is out of this ADR: the first version of the change judged these receivers that way, and it created
   proven dead fallbacks in `RPG2k::Scene::Map` (the nomethod reviewed-list and proven-miss checks fail on
   `mruby-rpg2k-compiled`, while master passes them). The method-flow position is not built.
6. Anything else (several definitions, mixed upvar and local, no SENDB binding) is refused.

**Narrowing.** Only rule 4 (block-local) and rule 3 (element refusal) give positions. A send whose receiver is a
method local, including an accumulator the body appends to (`acc << x`), is refused with `upvar_narrowed`. The
`@inline_loop_parent` state and its save/restore were removed with the method-flow path.

**Limit: class-narrowed receivers.** A receiver narrowed by a `respond_to?` test (CLASS_NARROWING, ADR 0290) is compiled
by the narrowing guard rather than through `closed_world_site`, so its sends get no flow position here. A
block-local receiver sent a plain method (`r = pick(i); r.wait`) is accepted and takes the proven nomethod tail.
The check's block-local world uses the plain shape; a `respond_to?`-narrowed world is not asserted either way.

The measurement below is the first version (rules 4 and 5 both on). It is not re-measured for the narrowed version.

Every refusal is counted by reason (`BC2CPP_LOOP_FLOW_REPORT=1` prints the counts at exit; `=2` one line per send).

**Kill switch.** `BC2CPP_LOOP_FLOW_POSITION=0`: `loop_flow_position` returns nil at once, so the site is the same
hash as before and every consumer sees the same nil. Measured: the shipped pass with the switch off is
byte-identical to `origin/master` 11fd1034.

**Consumers.** `site_flow_position(site)` returns `[irep, idx, insn]` from the site's own position or from
`site[:flow]`. `receiver_instances`, `refined_receiver_instances` and `nil_may_answer?` read it instead of the
site's fields. Nothing else changes; the element and local arms that use `idx || trace_idx` (ADR 0386 and earlier)
are unchanged.

## Measurement

wio closed world, shipped pass (`BC2CPP_COVERAGE_KEEP_DIR`, `scripts/bc2cpp_coverage_report.rb`), `origin/master`
`11fd1034` against the same tree with the change. Counts are `CLOSED_WORLD kept:` markers in `shipped.cxx`.

| `kept` reason | master | flow on | flow off |
| --- | ---: | ---: | ---: |
| `core_or_native` | 181 | 177 | 181 |
| `dynamic_install` | 33 | 33 | 33 |
| `singleton_definer` | 9 | 6 | 9 |
| `unlisted_class` | 2 | 2 | 2 |
| `opaque_definer` | 1 | 2 | 1 |
| total | 226 | 220 | 226 |

Flow off is byte-identical to master. With the change on, six kept markers are removed: the three `wait` sends in
`RPG2k::Scene::Map#resolve_key_input` (`singleton_definer`, now the proven nomethod tail, and the `KeyInputRequest`
arm stays as the direct call) and three `core_or_native` sites (`Game::Battle#enemy_autodestruct`,
`Game::State#to_lsd`, `RPG2k::Scene::Map#shop_lines`). One `core_or_native` site
(`Game::Battle#update_ally_ready_order`, `include?`) gets a set and is now refused by `opaque_definer`, which is still
by name. The six remaining `singleton_definer` sites (`row` in `Game::Battle#initialize`, `row_adjusted?`,
`select_battle_command`; `action` x3 in `attack_target`) still have no set the proof accepts after this change; what
blocks each one is the next measurement, not part of this change.

Positions given to the proof on the shipped pass: 360 block-local and 32 method-local (distinct body and position
pairs). Refused: 159 SSEND self calls (`draw_system_text`, `item_count`), 36 synthetic sends (the `each`/`times`
helper sends), 3 method-local positions with no SENDB binding, 1 method-local local written by the body
(`upvar_written`), no element reassignment. Generated text: `bc2cpp_send(` 1,883 to 1,877, `bc2cpp_nomethod(` 4,195
to 4,201, `mrb_funcall` unchanged at 10,687.

The guard arms removed by the proof, 62 `UNLISTED_CLASS_*` comment lines in ten functions (`apply_to_party` 17,
`build_parallels` (its rescue region) 15, `RPG2k::Scene::Map#start_autostart` 13, `draw_events` 7,
`pictures_signature` 3, `Game::Battle#initialize` 2, `rebuild_events_preserving_positions` 2, and
`do_change_exp`, `do_change_level`, `do_change_class` 1 each), are the unlisted-class arms of sends whose receiver
set is now exact: the element of a container whose class pool is exact, or a method
local whose set the flow proves at the loop. Their else arm is the proven nomethod tail. That claim rests on the
ADR 0296 class pools for inlined element receivers, the same premise the unguarded `INDEX_EXACT` and `NILABLE_RECEIVER`
arms already rely on. A wrong class pool would now show up as a dropped arm, not as a wrong guard; this is the
largest trust extension in this change and is the first thing to re-check if a run ever diverges.

## Checks

`scripts/bc2cpp_loop_flow_position_check.rb` (MRBC) generates four worlds through the closed-world generator:

* positive: a receiver the block defines in an inlined `each` is accepted (`local`), and its `wait` send becomes the
  proven nomethod tail;
* negative: a method-local receiver is refused (`upvar_narrowed`), its `wait` send is not a proven tail;
* negative: the element copy with the element reassigned is refused (`element_reassigned`) and stays by name;
* negative: an argument receiver has no set to prove, so no send of that world is a proven tail;
* switch off: nothing is read or refused, and the positive world keeps its singleton sends.

`LFP_MUTANTS=1` runs the same checks on two mutated copies of `tools/bc2cpp`: the wrong iteration position
(`trace_idx - 1`), and the element guard dropped. Plus the narrowing removed (`:upvar_narrowed` replaced by an accept).
Each must fail a check.

The existing `bc2cpp_exact_receiver_check` and `bc2cpp_unlisted_class_call_check` still pass with the change
(the second one on its generated-code section; its g++ section needs a full-core build and was not run here).

## Not built

* The six remaining `singleton_definer` sites: their receiver sets are not proven by this change.
* Positions of SSEND self calls (the receiver is self; the self-owner arms already cover them) and of typed index or
  splat helper sends, which have no SEND of their own.
* Profiler section bodies (`emit_profiler_section_inline`): they do not go through `compile_inline_block_body`, so
  their method-local receivers have no SENDB binding and are refused (`upvar_no_position`).
* Nested blocks inside an inlined body go through the BLOCK_FALLBACK function (`emit_proc_fallback_fn`), which
  already passes `idx`; they are not changed here.
