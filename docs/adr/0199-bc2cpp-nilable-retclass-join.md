# 0199. bc2cpp: class-or-nil return proof through joins, rescue and agreeing POLY names

Date: 2026-09-23

## Status

Accepted. Builds on ADR 0194 (RETCLASS_SELF_CALL_SUPPORT) and ADR 0198
(RETURN-site dominance guard).

## Context

Before ADR 0198, the whole-program coverage report listed 507 ivars as
`OPAQUE`: at least one `SETIV` site whose value `ClassLayout.analyze` could not
trace. Bucketing every untraceable site by the instruction that produced the
value showed that most of these ivars hold primitives (integer, boolean, symbol
or string literals, or arithmetic results). A class hint cannot help them,
because hints only drive calls to classes the registry knows. Of the 187
ivars with no primitive-shaped site, the buckets were:

| shape of the untraceable value      | ivars |
|-------------------------------------|------:|
| a method argument                   |    63 |
| a self-call (`@x = helper(...)`)    |    39 |
| a call on another receiver          |    38 |
| a local beyond the scan window      |    17 |
| a `GETIV` of another opaque ivar    |     8 |
| a constant                          |     6 |

Most method arguments are integers passed to `initialize` or to setters.
Enumerating call-site argument classes resolved one ivar. The self-call bucket
was the largest one that could be resolved soundly. Its callees are factories
such as `make_windowskin`, `build_chipset`, `load_chipset_graphic`,
`build_arrow_sprite` and `build_field_background`. They return one class or
`nil`, often from a `rescue` handler, and some are defined in several scenes.

ADR 0198 replaced `straightline_return_reg?`'s refusal of any jump target
with a dominance test. That test resolved `build_field_background`, whose join
does not touch the returned register (OPAQUE 507 -> 502). It still needs ONE
writer that dominates the `RETURN`, however. So it refuses a register with
several reaching definitions, such as `make_windowskin`'s constructor plus two
`nil`s, or `flag ? A.new : A.new`. `compute_class_return_names` also still
refused `RETNIL`/`RETURN_BLK`, catch handlers, and names with more than one
definition.

## Decision

Keep `compute_class_return_names`, its level-0/level-2 stratification, and ADR
0198's dominance machinery. For the class proof only, replace the
single-dominating-writer chain with the full set of reaching definitions:

- `return_value_sources` collects every definition of the returned register
  that reaches a `RETURN` or `RETURN_BLK`. `RETURN_BLK` in a method is a plain
  return. It is JOIN_REACHING_DEFS' walk (`fixnum_proof_preds`, the audited
  `FIXNUM_PROOF_STEP_OVER_OPS` whitelist, `fixnum_proof_writes_reg?`, the
  catch-target barrier) plus ADR 0198's level-aware `own_upvar_written_regs`
  barrier. The walk fails at method entry, at a raise edge, at an unaudited
  opcode, and at a call whose frame could overwrite the register. So every
  shape ADR 0198 refuses stays refused (`bc2cpp_return_join_check.rb`).
  `LOADNIL`, `RETNIL` and the fall-through edge of `RAISEIF Ra` (vm.c only
  continues when `regs[a]` is nil) count as `nil`. A single dominating writer
  is the special case of a one-element set.
- Each non-nil definition is traced from its own writer with ADR 0198's
  `dominated:` hook. The writer is exempt, because the set already accounts for
  every path into it. Every deeper hop, such as a `.new`, `.dup` or accessor
  receiver, must still dominate its use. ARRAY_RETURN_PROOF keeps ADR 0198's
  `straightline_return_reg?` unchanged, because an Array proof cannot allow
  `nil`.
- The fact is "class K or nil". Every ClassLayout hint already has that
  contract (NIL_TOLERANT_JOIN), and ClassLayout is the fact's only consumer.
  A method that only returns `nil` proves nothing.
- `rescue` handlers are allowed, because a handler entry is a barrier the walk
  never crosses. `ensure` handlers are still refused.
- A POLY name is admitted when every registry definition has a bytecode body
  and all of them prove the same class, because a self-call can reach any
  definition.
- Two admission guards cover paths the registry does not show. A name that the
  closed world aliases, `define_method`s or undefines is refused, and a
  non-literal installer call refuses every name. A self-call fact is used only
  when a definition sits on the caller's own superclass chain
  (`self_call_reaches_def?`), so the call can never reach `method_missing`.

## Consequences

Relative to ADR 0198, the number of `CLASS_HINT`s rises from 273 to 298 and
OPAQUE falls from 502 to 477. No existing hint changes or disappears.
Unresolved Array-element candidates rise from 36 to 37, because
`@player_intended_target` is now a proven Array. The proven return-name set
grows from 182 to 297 with nothing dropped.

The new hints include:

- `RPG2k::Scene::Map`'s `@chipset` and `@tiles_chipset` (`Game::ChipSet`).
- `RPG2k::Scene::Map`'s `@chipset_bmp`, `@tiles_chipset_bmp` and
  `@windowskin` (`Bitmap`).
- `RPG2k::Scene::Map`'s `@player_intended_target` (Array).
- Every menu's `@skin` and scroll arrows.

The generated code changes in three places. The per-frame tile paths now
inline the `@chipset.graphic`, `.animation_type` and `.animation_speed` reads as
guarded `mrb_iv_get`s. The bare RGSS class names in the `Bitmap` and `Sprite`
hints are not registry owners, so those hints are not consumed yet.

`scripts/bc2cpp_nilable_retclass_check.rb` covers each accepted and refused
shape. Mutation-testing each guard makes the check fail, including the
writer's `dominated:` exemption. The one exception is the `ensure` refusal,
which the catch-target barrier already enforces.
