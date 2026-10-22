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

## Summary (current gate)

Measured on `master` at `81709076` with the narrowed gate (see "Global gate" below).

| Count | Value |
| --- | ---: |
| methods | 3669 |
| with_constant_sites | 1637 |
| unresolved_methods | 531 |
| single_tuple | 1245 |
| pure | 91 |
| pure_single_tuple | 41 |
| jumps_in_single_tuple | 2236 |
| jumps_decided | 0 |
| unresolved_global | false |
| operator_gate_closed | false |

`jumps_decided` is 0 because the 634 single-tuple methods that have jumps all take zero arguments (`tuple=[]`), so no
parameter test is decided by a constant. The earlier measurement at `fec4dbbd`, before the gate was narrowed, had
`unresolved_global` true and `single_tuple` 0; the rows below are kept as that history.

## Global gate

The global refusal came from one site: the `define_method(n) { ... }` installers in the `ARRAY_FILES.each` and
`EDITION_FILES[...].each` loops of `mruby-rpgvx/mrblib/rgss_data.rb` (lines 62, 65) and `mruby-rpgxp/mrblib/rgss_data.rb`
(line 287). Their name is a block parameter, and LoopInstallers leaves all three loops unregistered, so each is a
computed-name `define_method`. `unresolved_calls` made any computed-target send global.

The gate now refuses a computed-target send only for the names `DynamicNames.universe` spells, the same universe the
call-site proofs use (ADR 0279). Every method name the program never spells stays a candidate. Two gates stay global:
a to_enum site with a computed name, and an alias AliasSites cannot decode.

## Refusal breakdown

Methods with at least one constant call site (1637) are refused for these reasons. A method can have several.

- **Unresolved (global):** 1637 of 1637 at `fec4dbbd`, before the gate was narrowed (see "Global gate" above). The
  computed-name `define_method` loop installers were the only source. Named unresolved names also appear (`sort`, `update`, `initialize`,
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
