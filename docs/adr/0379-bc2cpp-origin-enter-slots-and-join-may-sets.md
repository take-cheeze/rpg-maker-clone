# 0379. bc2cpp: the origin walk models every ENTER slot, passes through EXCEPT, and reports joins as may-sets

Date: 2026-10-10

## Status

Accepted

## Context

The exact receiver-origin table (`SiteOriginTable`, `docs/bc2cpp-dynamic-site-census.md`) labelled 527 of the 2,060 live
`bc2cpp_send` sites of the wio shipped pass `unknown` (master `5ddf1d98`, exact walk): 288 refused, 97 ambiguous, 135 exact
with an unclassified definition and 7 whose receiver is not a register. Refusal causes at the site level: 271
`unmodelled:ENTER`, 15 `unmodelled:EXCEPT`, 2 `opaque_reg`. Table-wide (9,704 rows) 1,778 of 1,811 refusals were ENTER.

The ENTER refusals were one shape: R1 of a method with a positional parameter and no keywords (1,241 rows are the sole
required parameter). The walk refused it because ENTER may rebind R1 (it unpacks a packed argument list into it), so R1 is
not the entry value, although every exit leaves the parameter's value there. The other unmodelled ENTER registers (post
arguments, locals) were refused for the same reason: no definition kind for them. Joins (`ambiguous`) carried no
information about what they merged, and an exact definition whose emitted text held several producers (a numeric fast path
and its send fallback), or no text at all, was `unknown`.

## Decision

Everything here is origin-only (`origin_transfers: true`, passed by `SiteOriginTable` alone). Codegen's walk and
`write_dominates?` (`typed_enter: false`) are unchanged.

1. **ENTER slots (`Program#enter_slot`).** From the vm.c layout (`3rd/mruby/src/vm.c` OP_ENTER): self and R2.. arguments (R1
   with keywords) keep their entry value; R1 without keywords is `:arg`; the rest, post, keyword-hash and block slots are
   ENTER-stored (`:rest`, `:post`, `:hash`, `:block`); every register from the first local up to `nlocals` is cleared to nil
   (`:local`, labelled `literal_or_fresh`). Precondition: the irep's `nlocals` is known. A register at or above `nlocals`
   (a temporary ENTER does not touch), or an irep without `nlocals`, refuses with `unmodelled:ENTER:temp`; an operand
   without eight ASPEC fields refuses with `unmodelled:ENTER:shape`. All ENTER-stored values other than the local's nil are
   labelled `parameter`.
2. **EXCEPT.** `OP_EXCEPT` writes only R[a], so any other register passes through it to the handler edges (reachable only
   under `through_handlers`; the normal walk still refuses at the guarded handler target). A raising send whose callee
   frame can reach the register still refuses.
3. **Joins as may-sets.** An `ambiguous` row's category is the sorted, distinct categories of its definitions joined by `|`
   (its definition column lists the writers). The census reads it as that origin when all agree, `join` when they differ
   (the set is kept in `origin_set`), and `unknown` when a member is `unknown`.
4. **Result labels.** When the producers in one instruction's emitted text disagree, or a call has no text, the writing op
   decides: a call is `call_result`, an operator (ADD, SUB, MUL, DIV, ADDI, SUBI, EQ, LT, LE, GT, GE) `operator_result`, an
   index op `indexed_result`. The label holds whichever arm ran because the op wrote the register. Any other op stays
   `unknown`.

Nothing is classified more precisely than the dataflow proves: the labels are about the writer, a join keeps every member,
and a refusal keeps a counted cause.

## Consequences

Measured on the wio closed world, shipped pass, base `5ddf1d98` against the change (`BC2CPP_COVERAGE_ORIGIN_TABLE`).
**`shipped.cxx` is byte-identical** (21,595,851 bytes, tags included): the change alters the census and the table only, no
generated code. Census sites:

| Receiver origin `unknown`, by sub-reason | Before | After |
| --- | ---: | ---: |
| refused `unmodelled:ENTER` | 271 | 0 |
| refused `unmodelled:EXCEPT` | 15 | 0 |
| refused `opaque_reg` | 2 | 2 |
| ambiguous (join) | 97 | 0 (128 ambiguous sites, each a `join` or one origin) |
| exact, definition unclassified | 135 | 0 (`call_result`, `operator_result`, `indexed_result`) |
| not a register | 7 | 7 |
| **unknown** | **527** | **9** |

Origins that grow: `parameter` 62 to 317, `join` 0 to 116, `call_result` 0 to 82, `operator_result` 0 to 26,
`indexed_result` 169 to 203. Table rows: refused 1,811 to 3; exact 7,607 to 9,367; ambiguous 286 to 334.

Remaining: 7 non-register receivers (a name, not a register) and 2 `opaque_reg` (a block's SETUPVAR may write the register,
which depends on the body of the called iterator). The 135 formerly unclassified are labelled by writing op, a coarser
kind than the text's `direct_call_result`/`dynamic_call_result`; a consumer that needs the text-level kind still has
`SiteCensus.origin_of`. The post-argument label assumes a post parameter implies a rest or optional one, which holds for
mruby's parser (vm.c skips the post move only when `argc - m2 <= m1` without both).

Checks: `bc2cpp_origin_multiwrite_check`, `bc2cpp_origin_transfers_check` (positive and negative per transfer),
`bc2cpp_origin_may_sets_check`, `bc2cpp_bytecode_ir_dataflow_check` (against mrbc output) and
`bc2cpp_origin_enter_mutation_check` (26 mutants).
