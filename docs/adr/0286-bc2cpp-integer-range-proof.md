# 0286. bc2cpp: integer range proof for arithmetic, compare and Array index sites

Date: 2026-09-30

## Status

Accepted

## Context

ADR 0276 proves which *classes* an operand may have. It removes the dynamic send from a guarded
`+ - * < <=` arm, but what is left is still the exact tier: the arm tests both operands for
`mrb_fixnum_p`, runs `mrb_int_add_overflow`/`_sub_`/`_mul_` (falling back to `mrb_num_add` on
overflow), and carries the Float and bigint arms after it. Most of that is dead once the operands
are known to be small: an index counter below `size`, a colour byte, `x % 10`, a layout constant.
Comparisons carry the same ladder (an OP_CMP tag-pair chain and a fixnum fallback), and an Array
read `a[i]` normalises a negative `i` on every call.

The question that started this: *could we prove the integer range of Array items?* An interval per
register is the easy half. The Array half is the hard one, because an Array is a mutable object:
its elements are the join of every value any alias ever writes.

Two facts about the targets constrain the answer. `mrb_int` is 64-bit on the native build and 32-bit
on Emscripten, Wio and PSP, and word boxing tags one bit, so the *fixnum* range is 62 bits natively
and only `[-2**30, 2**30 - 1]` on the 32-bit targets; anything larger is a bigint object there.
And the bytecode compiler runs once on the host, so a proof that a sum fits must hold for the
narrowest target or be decided by the C++ compiler with the target's own macros.

## Decision

**An interval domain (`tools/bc2cpp/int_range.rb`).** A range is `[lo, hi, cap]`, bounds exact
Integers or infinities, so it is a statement about mathematical Integers and never about `mrb_int`.
It says "*if* this value is an Integer, it lies here"; a register whose class set is not exactly
Integer keeps TOP at its source. Transfer functions cover `+ - * / % & | ^ << >> -@ ~ abs succ pred
min max clamp`, floor division (zero excluded from the divisor), `%` by a sign-known divisor, bit
masks (`x & 0xff` is `[0, 255]` for any `x`, a bigint included), shifts (negative counts are right
shifts) and comparison refinement. `IntRange::THRESHOLDS` drive widening. The algebra is checked
against the concrete operations on random members of random intervals and on every boundary of the
shipped targets.

**A forward dataflow beside NumericFlow (`tools/bc2cpp/range_flow.rb`).** State per instruction:
a range per register and ivar slot, the variable each register still copies, the comparison a
register still holds, and a "not nil" bit. A conditional branch narrows the operands of the
comparison it tests (`i < n` inside the loop body, `i >= n` after it, `== k` exactly). Loop heads
widen after two growth steps and two narrowing rounds recover the exit bounds. NumericFlow supplies
the classes: an operand that is not exactly Integer/Float, or whose operator is not the core body,
yields TOP. Ops that run Ruby the flow does not follow (an operator on a non-number, an index on
anything but an exact Array, string interpolation, hash or range construction, constant lookup)
refresh the ivar slots to their whole-program facts, in NumericFlow as well (`SILENT_CALL_OPS`):
ADR 0276's slot facts ignored them.

**Whole-program range facts (`codegen_range_proof.rb`)** are the join of what every writer stores,
on exactly the enumerations ADR 0276 already justified: pooled arguments (`@entry_arg_numeric`),
ivar groups, constants, tracked return names. They are computed after the class facts are final, as
a least fixpoint with widening (`RANGE_WIDEN_AFTER`), so `@i += 1` widens to `[0, +inf)` instead of
looping. An unadmitted key reads TOP.

**Loop counters (`codegen_numeric_blocks.rb`).** The parameter of a literal block over mruby's own
iterators is an Integer: `n.times`, `a.upto(b)`, `a.downto(b)`, `a.step(limit, by)` on Integer
operands, `ary.each_index`, `ary.each_with_index` (index), `(a..b).each` on Integer endpoints. The
block is a literal (`BLOCK` right before the `SENDB`), the iterator is mruby's own Ruby or C body
(no rival definition on the receiver's ancestors, `ClosedWorld#core_ruby_arm_safe?`, ADR 0270), and
it advances by `Integer#+`, so the counter is an Integer whatever the limit is. This adds the class
fact to the ADR 0276 fixpoint (it had none for block parameters) and the range fact to this one:
`times` gives `[0, n.hi - 1]`, `upto` `[a.lo, b.hi]`, and so on.

**Array element cells (`array_cells.rb`, `codegen_range_cells.rb`).** A token dataflow over every
irep decides where an Array can go. A register holds a set of tokens: UNK (anything untracked),
one token per allocation site (`[...]`, `Array.new`, fresh arrays from `dup`/`+`/`select`/...), and
one per ivar `(family, name)` and constant name that ADR 0276 admits. Storing an allocation into a
cell unifies them (Steensgaard). A token *escapes*, and its class loses all element facts, when it
is passed to or returned from anything the flow does not model: an argument or receiver of any
non-whitelisted call (native mutators such as `fill`, `map!`, `sort!`, `replace`, `send`,
`Marshal`), a returned or yielded value, an element of another container, a captured register (a
nested block can touch it anywhere), an `attr_reader`'d ivar, and any irep the flow cannot model
(a `rescue`). `instance_variable_get`/`instance_variables` or `const_get`/`constants` anywhere
disable ivar / constant cells. The whitelisted operations are read-only (`[] first last size min
max fetch include? ...`), block iterations (`each each_with_index map select ...`), and the
non-shrinking writers `push << unshift insert concat []=`; each one demands that the receiver is
*exactly* an Array (class set ARR, no UNK token) and that mruby's own method runs. A method whose
callers all drop the result (`initialize`, or a name whose every call site starts the next
statement) does not leak the Array it ends with.

Each class carries a summary: the class set of its elements, their range, and a lower bound of
their length (the minimum over its allocations; only non-shrinking writers exist, so it holds for
every Array in the class at every time). Reads consult it:
`a[i]` is INT|NIL unless the class is non-empty and `i` is provably inside `[0, len)`, in which
case RangeFlow's "not nil" bit lets the emitter treat the read as an exact Integer; `a.first`,
`a[0]`, `min`, `max`, `sample` need `len >= 1`; `fetch` cannot miss; a block parameter of
`each`/`map`/... is the element (unless the block spreads it: arity > 1 over Array elements). An
indexed write past the proven length pads with nil and adds nil to the class.

**Emission.** All three sites are guarded by `range_fit_condition`:
1. `+ - *` (ADD/SUB/MUL/ADDI/SUBI/ADDILV/SUBILV): when both operands are exactly Integer and the
   *operands and the result* fit, the arm is `r = mrb_fixnum_value(mrb_fixnum(a) op mrb_fixnum(b))`
   with no overflow tier, no Float arms and no fallback. If everything fits `[-2**30, 2**30 - 1]`,
   the narrowest fixnum range of any shipped target (a `static_assert` on `MRB_FIXNUM_MIN/MAX`
   documents it), the arm is unconditional. If it fits only a wider interval, it is emitted as
   `if (bc2cpp_range_fits(lo, hi, cap)) { pure } else { existing arm }` where the constexpr function
   compares with the target's `MRB_FIXNUM_MIN/MAX`, and a range derived from the Array length cap
   additionally requires `SIZE_MAX / sizeof(mrb_value) <= 0x3fffffff` (the bound `ARY_MAX_SIZE` of
   src/array.c enforces on every growth); beyond 2**62 the exact arm stays.
2. `< <= > >= ==`: the same, as one native fixnum comparison.
3. Array read `a[i]` with `i` exactly Integer and `>= 0`: `bc2cpp_ary_entry_nn` (or
   `bc2cpp_getidx_nn`, falling back to `bc2cpp_getidx`) skips the wrap-around of a negative
   index. It compares `(mrb_uint)n >= (mrb_uint)len`, so a proof that were ever wrong yields nil,
   never an out-of-bounds read. `Array.new(n[, v])` with `n` a non-negative fixnum allocates at its
   final size and fills, instead of `mrb_obj_new` plus a dispatched `#initialize`.

**A pluggable oracle.** `RangeFlow` asks its oracle for everything it does not derive itself
(`entry_range`, `ivar_*_range`, `const_range`, `upvar_range`, `return_range`, `element_range(query)`,
`element_in_bounds?(query)`, `op_native?`, `core_send_safe?`). `ElementQuery` carries the
instruction, the container register and class set, the key register, range and class set, and the
reader name. A record/schema oracle for LCF hashes (`rec[:field]` is an Integer in `[lo, hi]`)
implements `element_range` and `element_in_bounds?` for receivers whose class set is HSH; the
Array oracle here answers TOP for those. Nothing else changes: the emitters consume only the
resulting ranges and the class sets.

## Soundness, per part

1. *Domain.* Every function is monotone and checked against the concrete operation; widening only
   enlarges, so any post-fixpoint is sound. Bignums are ordinary Integers; nothing is cast to
   `mrb_int` unless the whole interval fits the fixnum range, and an Integer inside that range is a
   fixnum because mruby normalises every Ruby-visible bigint result (`bint_norm`).
2. *Flow.* A range is used only where NumericFlow proves the class exactly Integer (or
   Integer-or-nil with the not-nil bit); every op that writes more than its leading register or
   runs unseen Ruby resets what it can change; a register a nested block writes is TOP.
3. *Facts.* A key exists only where ADR 0276's enumeration argument admitted it, so "every writer is
   visible" is inherited. `NATIVE_ARG_TARGETS` parameters read TOP (natives call them).
4. *Arrays.* The escape rules above; the Marshal/native/subclass cases fall out because their
   values are UNK, and storing UNK into a cell poisons it. Allocation tokens are exactly Arrays
   (ARRAY/`Array.new`); a fresh-array method is trusted only for an exactly-Array receiver.
   Unmodelled ireps poison the cells they touch.
5. *Targets.* The unconditional arm needs only the 31-bit intersection of every target; the guarded
   arm evaluates `MRB_FIXNUM_MIN/MAX` in C++, so a 32-bit build takes the exact arm exactly when
   the interval reaches `2**30`. `scripts/bc2cpp_int_range_check.rb` evaluates `bc2cpp_range_fits`
   for the 31-bit, 62-bit and nan-boxing layouts.

## Consequences

- Measured on the wio closed world (`BC2CPP_RANGE_COVERAGE=1`): of 2531 arithmetic sites 701 have
  exactly-Integer operands and 323 (12.8%) have a proven bound (288 fit every target, 35 are
  decided by the target's fixnum range); of 1627 compares 27 are bounded; of 3701 index sites 301
  (8.1%) are proven non-negative. 244 `RANGE_PROOF` sites are emitted, `bc2cpp_send(` calls drop
  10336 to 10260 and the output shrinks by about 5 KB. `mrb_int_*_overflow(` calls *rise* 130 to
  170: loop counters that were bare wrapping fixnum adds are now class-proven and take the
  overflow-checked tier where no bound is known. Only a small sound subset pays off: Array elements
  are Integer-exact mostly through iteration parameters and constant tables, most local arrays hold
  unknown elements, and LCF record fields need the schema oracle.
- Payoff: the overflow tier and the
  Float and bigint arms disappear from the sites the proof covers, compare arms shrink to one
  statement, and array element reads gain exact classes where the Array is fully visible. Class
  proofs (ADR 0276) already removed the dynamic sends; this buys speed and code size, not dispatch
  counts. Most arithmetic in the engine works on values the compiler cannot type (LCF record
  fields, arguments from such values); those keep the exact tier until a schema oracle supplies
  their ranges.
- Cells are cheap to lose: an Array that any function receives, returns or hands to `send` has no
  facts. Methods that end in `@list << x` are handled by the discarded-result rule, not by
  magic; a getter (`def items; @items; end`) refuses the cell for good.
- Findings outside this change: the plain fixnum tier and the *Fixnum*-proven arm
  (`FIXNUM_OPERAND_PROOF` source 4) still store `mrb_fixnum_value(a op b)`, which wraps on 32-bit
  targets past `2**30 - 1`; the range facts could bound them but do not touch them here. ADR 0276's
  slot facts ignored hidden Ruby calls (fixed here). A computed-name `send` fed from external data is
  outside the model, as in ADR 0276.
- `scripts/bc2cpp_int_range_check.rb`: the algebra against the concrete operations, RangeFlow on
  hand-built bytecode, generated-code assertions, mutation fixtures for every kind of unseen writer,
  the fits predicate for three fixnum layouts, and compiled-vs-interpreted runs at `MRB_FIXNUM_MAX`,
  `MAX + 1`, `MIN - 1`, `2**30`, `2**31`, `2**62`, negative shifts and moduli, and Arrays written from
  another path, by a native mutator, through a subclass and from a native producer.
