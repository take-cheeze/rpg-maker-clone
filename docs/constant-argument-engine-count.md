# Constant-argument sites on the engine

A measurement of `ConstantArgumentSites.report` (`tools/bc2cpp/constant_argument_sites.rb`) over the engine's
mrblib sources. The analysis is report-only: nothing in the generated C++ changes.

## Setup

- Source: `master` at `fec4dbbd`, all 54 `mruby-*/mrblib/**/*.rb` files compiled together with `mrbc`, so call
  sites cross files.
- Registry and ireps from `build_registry` and `compile_ireps` (the same path as
  `scripts/bc2cpp/constant_argument_sites_check.rb`).
- `ConstantArgumentSites.report(ireps, registry)` with the default `constants: {}`. Constants therefore come only
  from literal arguments at a call site. ConstantFacts (ADR 0501) is not used.
- The driver is a scratch script and is not committed.

## Summary

| Count | Value |
| --- | ---: |
| methods | 3669 |
| with_constant_sites | 1637 |
| single_tuple | 0 |
| pure | 91 |
| pure_single_tuple | 0 |
| jumps_in_single_tuple | 0 |
| jumps_decided | 0 |
| unresolved_global | true |
| operator_gate_closed | false |

`single_tuple` is 0 because `unresolved_global` is true, so every method is unresolved and `single` is never set.

## Refusal breakdown

Methods with at least one constant call site (1637) are refused for these reasons. A method can have several.

- **Unresolved (global):** 1637 of 1637. The engine has a computed-target dynamic send, which makes every method
  unresolved. I did not identify the specific site. Named unresolved names also appear (`sort`, `update`, `initialize`,
  `private`, `public`, `module_function`, and the `__mrb_native_*` and `_rgss*` helpers), but the global flag is what
  refuses every method.
- **Impure:** 1515 of the 1637. The most common impure ops are `GETIDX`, `SETIV`, `BLOCK`, `RETNIL`, `ARRAY`, `STRCAT`,
  and sends such as `new`, `save_put`, `read` and `each`.
- **May raise only** (impure set empty, may-raise non-empty): 100 methods in total. The most common may-raise ops are
  `GETCONST`, `GETMCNST`, `MUL`, `ADD`, `LT`, `SUB`, `GT`, `DIV`.
- **Tuple check:** not separately counted. `single` requires a resolved method, so the unresolved refusal hides
  whether the call sites agree on one tuple. The counterfactual below shows that tuple count.

Loop installers: 3 of 3 are left dynamic and are not registered as definitions. The analysis prints this on stderr.

## Cross-check

Not run. The `call_tuple_hook.rb` recorder was not used in this measurement.

## Counterfactual (scratch only)

To see what the global flag hides, I ran the same measurement with `unresolved_reason_for` forced to nil, in a
scratch copy and not in the tree. This is not the shipped analysis:

- `single_tuple`: 1411
- `pure`: 91
- `pure_single_tuple`: 62
- `jumps_decided`: 0

So the global unresolved gate removes almost all single-tuple candidates. Even with it lifted, no jump is decided
by the constant tuples on the engine.

## What is assumed

- Constants are literal arguments only. Named constants and ConstantFacts are not used.
- The result describes this `master` snapshot and the mrblib files compiled together. The engine's native sources are
  not included.
- The counts are a measurement. They do not change codegen, and this change does not turn any optimisation on.
