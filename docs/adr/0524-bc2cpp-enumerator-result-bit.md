# 0524. bc2cpp: a blockless Enumerable iterator result is a reserved Enumerator bit

Date: 2026-10-20

## Status

Accepted

## Context

A bare `SEND` of an Enumerable iterator such as `map` or `collect` on an exact core receiver
that includes Enumerable (Array, Hash, Range) has no block, so mruby returns `to_enum(:name, *args)`
(`3rd/mruby/mrblib/enum.rb` and `mruby-enum-ext`, with aliases such as `map collect`). The block form (`SENDB`) returns an Array, and ADR 0338 and the
block-iterator declarations (`core_block_iterators`) already type it. The bare call stayed
unknown, because the flow had no way to name an Enumerator result.

NumericFlow allocates class bits on demand (`CodeGen#numeric_class_bit`). A class bit
carries a class name, and several consumers turn a bit into a name for a class test,
a return class or a pool. Those consumers (`bytecode_ir_mask_classes`, `return_class_of_mask`,
the user-receiver union plans, class narrowing, escape analysis) assume a bit names an
allocated class. An Enumerator bit with a name would reach them as a class the program
may not declare.

## Decision

Reserve one bit for the blockless Enumerator result. `NumericFlow::ENUMERATOR_BIT` is
`OBJECT_KIND_BASE - 2` (318) and `NumericFlow::ENUMERATOR` is that bit. It is not
allocated by `numeric_class_bit`, which now refuses bit `ENUMERATOR_BIT`, so no class
name is ever attached to it. Every consumer that names a class from a bit therefore
refuses the value and treats it as unknown. Escape analysis also names only allocated
class bits, so the bit alone yields no name there either.

The blockless result is declared in `core_blockless_iterators` as the method-level union of
the Enumerable iterators mruby answers with `to_enum` (26 names). Every member is the method-level
union of its two forms: the blockless overload (`-> Enumerator`, with the arity its call accepts) and
the block overload. The block overload's result is the class `core_block_iterators` declares for it
(`map`, `collect`, `reject`, `find_all`, `partition`, `filter_map`, `sort_by`, `group_by`), else
`untyped`; it is not `self`, so `BlockReturns` does not take the member as a checked block-return
declaration. The loader refuses a member that has only one form. `CoreBlocklessIteratorSigs`
reads the results and the arity. `find_index` is not declared: its blockless call with an argument
is not an Enumerator.

`CodeGen#native_core_blockless_enumerator_result` gives the bit to a `SEND`/`SEND0` of a
table name on an exact core receiver whose class includes Enumerable (`CoreHierarchySigs`), with an
argument count the declaration accepts, under the gates of the block form: exact
instances, no installed name, every registry definition native, and the kill switch
`BC2CPP_NATIVE_CLASS_RESULTS=0`. It is checked by `scripts/bc2cpp/enumerator_result_check.rb`.

## Consequences

- A blockless Enumerable iterator result is known to be an Enumerator, which is not nil, not
  an Array and not a Hash, but its class is not named. Codegen gains no class test or
  direct call from it; the gain is that its downstream results are no longer treated
  as untyped by the flow.
- The reserved bit lowers the ceiling for numeric class bits by one. `ENUMERATOR_BIT`
  is the new limit, and the allocator raises before it.
- A later change that wants to name Enumerator as a class must give it a stable
  constant and audit each consumer above, rather than reusing this bit.
