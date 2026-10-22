# 0541. bc2cpp: the else of a static Array or Hash `[]` runs the shared getidx helper

Date: 2026-10-22

## Status

Accepted

## Context

A `[]` site whose receiver class is statically proven to be Array or Hash emits an inline fast path (`bc2cpp_ary_entry`
for a fixnum key, `mrb_hash_get` for a Hash) and an `else` for everything else. That `else` was a by-name send at the
site, so each such site kept its own dynamic call. The shared helpers `bc2cpp_getidx`, `bc2cpp_getidx0` and
`bc2cpp_setidx` already re-check the receiver and key, cover Array, Hash and String directly, and under the closed
world (INDEX_CLOSED, ADR 0365) answer every other class from a closed switch with a proven NoMethodError.

## Decision

- The Array `else` (a non-fixnum key, or a receiver that is not an exact Array) and the Hash `else` (a non-Hash
  receiver) call `bc2cpp_getidx` through `CodeGen#index_else_statement`. The helper's arms repeat the same tests, so
  the result is the same call as before for every receiver.
- When `[]` is devirt-blocked by a runtime definer, the statement stays the by-name `mrb_funcall`, as before.
- INTEGER_TAG_ELSE (ADR 0394) still runs the Array body directly for an exact Array receiver and is unchanged.

## Consequences

- In the shipped wio build the remaining by-name sends drop from 746 to 669 bodies. The 76 removed are the
  `core_tag_chain_else:receiver_other` sites for `[]`, and one `owner_chain_default_else`.
- The by-name `[]` now lives in one helper, shared across the sites, instead of at each one.
- Not verified at runtime. The closed library builds with the change. The index-related bc2cpp checks
  (`class_pools_check`, `dispatch_ir_trace_check`, `join_dominance_check`, `lcf_row_flow_check`) pass. The coverage
  summary still stops at its known label mismatch, after the shipped file is written.
- `[]=` (setidx) has the same kind of else and is not changed here.
