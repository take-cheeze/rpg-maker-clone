# 0421. bc2cpp: a Symbol element of a frozen literal carries the Symbol class bit

Date: 2026-10-12

## Status

Accepted

## Context

FROZEN_TABLES (ADR 0306) gives a frozen literal Array or Hash the class set of each slot, so `TABLE[i]` is a
known class where the index is a proven Integer. A slot is classified from the op that wrote it, and only the literal
ops count (`LOADI*`, `LOADL` of a Float or bignum, `STRING`, `LOADNIL`, `ARRAY`, `HASH`, `RANGE_*`, an Integer
constant). A `LOADSYM` slot was OTHER, so a table of Symbols such as `MODES = [:switch, :item].freeze` read back OTHER
even though it can never change.

The exact-class run (RETURN_CLASS_TABLE, ADR 0289) already gives a `LOADSYM` literal the 'Symbol' class bit, allocated
by `CodeGen#numeric_class_bit` and switched by `BC2CPP_IMMEDIATE_CLASS_BITS`. The numeric flow (NumericFlow, ADR 0276)
has no such bit for a Symbol, so the two flows disagreed about the same value.

The bit has to be sound in every consumer of the numeric masks. The numeric masks cross methods only through return
values (ADR 0289 and `@numeric_return`); arguments, ivars, constants and class pools refuse every class bit through
`NumericFlow::OPAQUE`. A Symbol is an immediate `mrb_sym` (LOADSYM emits `mrb_symbol_value`), so a consumer that
dereferenced `mrb_obj_ptr` for a class name would be wrong, and a consumer that compared a mask for exact equality
could be fooled by one more bit.

## Decision

The frozen-table slot reader gives a `LOADSYM` slot the Symbol class bit. The bit is the one the exact-class run already
uses, so there is one bit per class in every flow (`CodeGen#frozen_symbol_bit`, `numeric_class_bit('Symbol')`).

* Allocation: `setup_frozen_tables` allocates it before any flow, only when frozen tables are on and the Symbol switch is
  on, so every flow numbers the bit the same way. The bit is not a new constant; the other class bits keep their
  first-use numbering.
* Gate: `BC2CPP_SYMBOL_CLASS=0` (and `BC2CPP_IMMEDIATE_CLASS_BITS=0`, which switches every Symbol class bit) gives
  OTHER for the slot. With the switch off no bit is allocated, so the output is the output of the tree without this
  change.
* Only `LOADSYM` is a Symbol. A Symbol made at run time (`SYMBOL`, `"x".to_sym`) is OTHER.
* A Symbol that reaches a numeric flow is an ordinary class bit: a `FrozenTables` read of a literal index in range is
  the slot, an Integer index that is not a literal is the join with nil, and a Hash literal key reads its value (the
  same rules as every other slot; `FrozenTables::Registry#read` is unchanged).

Consumers of the numeric masks were audited (see `docs/bc2cpp-symbol-class.md`). Each either refuses a class bit it does
not name (`numeric?`, `== NumericFlow::INT`, `OPAQUE`, `CONTAINERS`, the core-bit subsets, the frozen-table subset
check, `exact_owner`), maps it to OTHER (`arith`, `tuple_position_mask`, the LCF foreign bits, the owner table of
`numeric_send_mask`), keeps it as a same-frame class (block captures, `@numeric_return`), or is diagnostic only. The
exact-class run never reads a numeric mask, so the bit cannot reach its emitters. Where a consumer names the bit
(class narrowing), the verdict for Symbol comes from the closed-world class chain; an unknown verdict passes both edges,
and a membership test is emitted only for a declared class and compares `mrb_obj_class`, which is correct for an
immediate.

## Consequences

* A Symbol table is a known class in the numeric flow. Its reads are SYM (or SYM|NIL) rather than OTHER, which can
  only remove a refusal, never add a claim about a value outside the table.
* The bit is one more class bit below the CHECKED provenance bit and the object kinds; the allocation limit
  (`CLASS_BIT_BASE` to `OBJECT_KIND_BASE - 1`) is unchanged in kind, one bit higher in use.
* Output changes only where a numeric mask with the bit reaches an emitter, and the measurement in
  `docs/bc2cpp-symbol-class.md` records that; the kill switch restores the earlier output exactly.
* The check `scripts/bc2cpp/symbol_class_check.rb` covers the model, the facts report, the kill switch and two hostile
  worlds (a redefined `Array#freeze`, a `const_missing`).
* Not done: a Symbol literal in a register (`LOADSYM` outside a table) is still OTHER in the numeric flow. Giving it
  the bit would widen the numeric flow's view of every Symbol and needs its own audit; it is left to a follow-up.
