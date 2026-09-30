# 0276. bc2cpp: numeric operand proof drops the send from guarded arithmetic and compare arms

Date: 2026-09-30

## Status

Accepted

## Context

About a third of the dynamic-send sites that survive in the shipped wio build are the else
of a guarded arithmetic or compare arm (`+ - *`, `/`, `< <= > >=`): the arm tries an inline
fixnum tier, an inline Float tier, and then `bc2cpp_send(...)`. The last resort exists only
because the operands are not *proven* to be numbers. `FIXNUM_OPERAND_PROOF` (ADR 0187, 0198,
0261) proves "a small Integer" from literals, loop counters, integer constants, hand-vetted
arguments and single-definition Fixnum returns. It knows nothing about Float, nothing about a
value that may be a bigint, and nothing about an ivar that `@i += 1` keeps Integer.

Two facts about mruby's numeric helpers make a weaker, broader proof sufficient. `mrb_num_add`,
`mrb_num_sub`, `mrb_num_mul` and `mrb_cmp` are the very bodies `Integer#+`, `Float#+`,
`Integer#<` and friends run, for any Integer (fixnum or bigint) or Float receiver and operand,
and they promote an overflow to a bigint themselves. So a site whose operands are proven
"Integer and/or Float" needs no dynamic send even when the values do not fit an `mrb_int`.

Nothing here may assume a value fits `mrb_int`: on the 32-bit targets (Emscripten, Wio, PSP) a
fixnum is 31 bits and larger results are bigints.

## Decision

**A class-set lattice and a forward dataflow (`tools/bc2cpp/numeric_flow.rb`).** Each register
holds the set of classes it may hold: `INT` (fixnum or bigint), `FLT`, `ARR`/`HSH`/`STR`
(exactly that class), `NIL`, `OTHER` (anything else). Join is union, so the answer cannot
depend on visiting order. The transfer functions cover the audited "writes only its leading
register" opcodes (`BytecodeIR::WRITES_LEADING_REG_OPS`); an irep with a catch handler or any
other opcode has no facts. A call clobbers every register above its receiver. A conditional
branch narrows the tested register by truthiness (`return unless x`), and the registers and
ivar slots it was copied or loaded from. `OP_ENTER` with optional arguments adds edges to
every slot of its jump table. Registers a nested block writes (`SETUPVAR`) are never numeric.

**Sources, all unguarded:**

- literals, `LOADL` pool entries, the closure of `+ - * /` (and `%`, `fdiv`, `abs`, `-@`,
  `to_i`/`floor`/..., `to_f`) over proven operands, gated by `builtin_class_send_safe?`
  (no Ruby override, no prepend) so the send would have run the core body;
- **entry arguments** pooled over every call site (`ENTRY_ARG_CALLSITE_PROOF`'s admission and
  exhaustive-site argument, unchanged), now as class sets and joined instead of "all Fixnum",
  refusing names a computed-name `send` could build (`numeric_dynamically_named?`);
- **instance variables**, one whole-program class set per (family, name) where a family is a
  connected component of the class graph (superclass, include, prepend). The set is the join of
  everything any `SETIV` stores. It is untracked when a native or foreign source spells the name
  (`@name`, `MRB_IVSYM`), bytecode names it as a Symbol/String (`instance_variable_set(:@x)`),
  an irep with no owner touches it, an attr_writer writes it, or reflection could write any
  ivar (computed `instance_variable_set`, `instance_eval` and friends, which rebind `self`,
  disable the proof). A slot starts as `set | NIL` unless every constructor assigns it before
  `self` can reach other code (`numeric_ivar_assured?`, built on the INIT_ASSIGNED must-analysis
  of ADR 0261, extended to model `super`), so a read outside `#initialize` cannot see nil;
- **return values** by name, joined over every definition (`NUMERIC_RETURN_PROOF`), only for a
  name that no native or foreign source defines, that no runtime installer or alias renames, and
  with no `method_missing` anywhere. `attr_reader`s read the ivar set. `SENDB` never uses the
  result (a `break` becomes the call's value);
- **constants**, the same argument keyed by bare name as `INTEGER_CONSTANT_PROOF`, decided by the
  flow, so `HEADER_H = LINE_H + Window::BORDER * 2` and `ROWS = SCREEN_H / TILE + 1` qualify;
- **captured locals** read by a block (`GETUPVAR`): the defining frame's class set at the
  creating `BLOCK` joined with every value ever stored into that register (`numeric_upvar_mask`);
  a register a nested block writes (`SETUPVAR`) is never numeric;
- Array/Hash/String literals, and `size`/`length`/`count` of an exact one, are `INT`.

The four fact families feed each other, so they are computed as one **least fixpoint of
may-sets** (`compute_numeric_facts`): every fact starts empty and only grows, and a fact that
reaches an unmodelled class is dropped for good. Any post-fixpoint is sound (each stored value's
class set is included in the set, by induction over the events of one run), and the sets only
grow, so it terminates. The dataflow is monotone in the masks it reads, and the worklist joins
into its states, so a stale contribution can only over-approximate.

**Nil is modelled, not assumed away.** An arithmetic operator on `nil` raises when no Ruby
definition on `NilClass`/`Object`/`Kernel`/`BasicObject`, no native `nil_class` registration and
no `method_missing` could answer it (`numeric_nil_raises?`); then the operand contributes no
value and `@i += 1` on an ivar that may be nil still yields `INT`. The *site* is only relaxed when
the operand is exactly numeric, so `r = maybe_nil; r + 1` keeps its send and `r ? r + 1 : 0`
loses it.

**Emission.** `compile_operator_fallback` returns the core helper call instead of the send when
both operands are numeric: `mrb_num_add/sub/mul`, `bc2cpp_num_div` (a mirror of `int_div`/
`flo_div` including bigints), `bc2cpp_num_cmp` (`mrb_cmp`, i.e. `cmpnum`, raising ArgumentError
as `num_lt` does). The arm's inline tiers stay; for these operands the fixnum tier is
overflow-exact (`mrb_int_*_overflow`, `mrb_int_value`) and leaves an overflow to `mrb_num_*`,
where the plain tier stores `mrb_fixnum_value(a op b)`, which wraps and mis-tags a result past
the fixnum range. The diagnostic prints `== numeric operand facts ==`; the coverage report counts
the facts and the arms that lost their send.

## Soundness, per proof

1. *Dataflow.* Register writes are exactly the audited list; calls clobber the registers above
   their receiver; captured registers are opaque; an unmodelled irep has no facts. Refinement
   only uses `nil`/`false` being the sole falsy values and provenance that is cleared on any
   write to either side, on a call, and on `SETIV`.
2. *Arithmetic closure.* The result of a native operator on numeric operands is `INT` only for
   Integer op Integer (an overflow is a bigint or a RangeError, never a Float), otherwise `FLT`.
   Bigint-blind reasoning is absent by construction: the masks never say "fits `mrb_int`".
3. *Pooled arguments.* Same enumeration argument as ENTRY_ARG_CALLSITE_PROOF plus the
   computed-name refusal above. Pooling admits only single-definition, pure-mandatory-arity
   methods whose name no outside source spells.
4. *Ivars.* Every store to a slot is a `SETIV` the scan sees (the exclusions above), so the
   union of their class sets bounds the slot; reads add `NIL` unless construction assigns first.
   Objects are made by `Class#new` (`standard_constructor_lookup?`); `Marshal.load` of hostile
   data, which could allocate a closed-world class without `initialize`, is outside the model,
   as it already is for every embedded ivar. The helpers are memory-safe even then
   (`mrb_num_*`/`mrb_cmp` raise on a non-number), so the failure would be an exception of a
   different class, not corruption.
5. *Returns.* A call reaches only registry definitions (`name_fully_visible?`), so the join over
   them bounds the result.
6. *Constants.* Every definition is a visible `SETCONST` (CLASS/MODULE, native and foreign
   definitions poison the name), joined over all scopes.

7. *Captured locals.* The block runs after its closure exists, so it sees the value the frame had
   at `BLOCK` or any later store of that frame; both are in the mask, so a local assigned only
   after the block was created stays `NIL` and keeps its send.

## Consequences

- Measured on the wio closed world (`scripts/bc2cpp_coverage_report.rb`, shipped build):
  guarded arithmetic/compare arms that still end in a dynamic send fell from 3,032 to
  **2,862** (`+ - *` 1,801 to 1,671, compare 937 to 912, Float `/` 294 to 279).
  Analysis adds about 6 s to a 60 s bc2cpp run.
- What is left is dominated by values that come from data the compiler cannot type: hash and
  array elements read from the LCF database, arguments passed from such values, and getters
  that return them. Remaining reasons are listed in the branch report.
- Findings outside this change, not fixed here: the plain fixnum tier and the *Fixnum*-proven
  arm (`FIXNUM_OPERAND_PROOF` source 4) store `mrb_fixnum_value(a op b)`, so a sum, difference or
  product that leaves the fixnum range wraps instead of becoming a bigint (2^30 on the 32-bit
  targets); and ENTRY_ARG_CALLSITE_PROOF/FIXNUM_RETURN_PROOF do not consider computed-name
  `send` sites (`target.send("#{field}=", v)`).
- `scripts/bc2cpp_numeric_operand_check.rb` pins the dataflow on hand-built bytecode, the
  generated code of a closed-world fixture (positive and negative cases), and, with a mruby
  build, compiled-vs-interpreter answers including Integer overflow.

## Addendum: `alias` poisons both names

`entry_arg_call_index` poisoned only the new name of `alias new old`, so a call through `new`
reached `old`'s body unseen and a parameter could be proven Integer while `new("str")` passes a
String. The ALIAS instruction now also poisons the old name (`alias_method`, `define_method` and
`undef_method` take symbol arguments, which already poison every name they mention).
`scripts/bc2cpp_entry_arg_alias_check.rb` pins the alias, `alias_method` and no-alias control cases.
