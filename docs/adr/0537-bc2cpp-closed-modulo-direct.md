# 0537. bc2cpp: `%` in the numeric slow path calls Integer#% and Float#% directly

Date: 2026-10-21

## Status

Accepted

## Context

The numeric slow path's `%` helper (`bc2cpp_slow_mod`, ADR 0292) handled a bigint or Integer receiver
inline, but sent every other receiver by name, Float receivers included. ADR 0367 already exports the
whole bodies of `Integer#%` (`mrb_int_mod_impl`) and `Float#%` (`mrb_flo_mod_impl`) from the mruby patch
`patches/mruby-expose-misc-bodies.patch`, but the generated helper never called them: the closed form
for `%` was left out, so the by-name arm stayed on every `%` slow-path call.

## Decision

- The C++ prelude declares `mrb_int_mod_impl` and `mrb_flo_mod_impl` (the latter under `MRB_NO_FLOAT`).
  The symbols come from the existing patch; nothing new is exported.
- `CodeGen#numeric_slow_mod_direct?` closes `%` when:
  - the closed world holds and the collection pin for `%` is ready;
  - `Integer` and `Float` are plain global constants;
  - `%` has no singleton, no class-level native, no Ruby and no module definer;
  - the native definers of `%` are exactly `Integer` and `Float`;
  - the foreign definers are at most `String` (mruby-sprintf's `String#%`).
  Under those conditions the only `%` that can answer an Integer or Float receiver is the native body.
- `CodeGen#numeric_slow_closed_mod_source` calls `mrb_int_mod_impl` for an Integer or bigint receiver and
  `mrb_flo_mod_impl` for a Float receiver, then restores and protects the arena like the other closed
  forms. Any other receiver (String, user objects) still goes by name, so the String arm is unchanged.
  Zero divisors, `MRB_INT_MIN` and the Float/bigint cases raise the method's own error, because the
  bodies are the methods.

## Consequences

- In the shipped wio build the `%` helper's by-name arm is now only for receivers it does not own.
  The helper region's `bc2cpp_send` count goes from 13 to 12. The count of call sites in bodies is
  unchanged, since those are callers of the helper, not by-name calls.
- A tree without the patch fails to link, rather than silently keeping the by-name arm. Every build that
  applies the patch chain (`cmake/build-mruby.cmake`, `scripts/mruby/standalone_prep.bash`) has it.
- Not done: a user-defined `%` on Integer or Float (a Ruby definer) still turns the closed form off and
  keeps the by-name arm. Calling the compiled body directly for that case is the ADR 0371 / ADR 0374 path
  (`block_core_target`, as `numeric_slow_zero` does for `zero?`) and needs its own proof. Tracked as
  follow-up.
- Not verified at runtime here. The closed library builds and the shipped C++ contains the new helper.
  `scripts/bc2cpp/numeric_operand_check.rb` fails in this environment on the unchanged tree as well
  (`no such class in the program`), so it does not exercise this change.
