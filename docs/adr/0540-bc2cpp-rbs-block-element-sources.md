# 0540. bc2cpp: block iterator element sources come from the RBS declarations

Date: 2026-10-21

## Status

Accepted

## Context

The numeric element mask for a block iterator (`block_element_class_mask`) was gated on a hard-coded name list
(`map`, `collect`). Other iterators whose Array elements are known (`filter_map`, and `select`, `reject`, `find_all`,
`sort_by` on Array) were not typed anywhere, so their elements stayed unknown.

## Decision

- `sig/bc2cpp/declarations.rbs#core_block_iterators` states each element source with a type variable:
  - `:block_return`: `def map: [U] () { (untyped) -> U } -> Array[U]` (also `collect`, `filter_map`). The elements
    are the block's returns; `filter_map`'s are a subset of them, so the declared type is a sound superset.
  - `:receiver`: `class Array[unchecked out Elem]` with `def select: () { (Elem) -> untyped } -> Array[Elem]` (also
    `reject`, `find_all`, `sort_by`). The elements are the receiver's, unchanged.
- `CoreBlockIteratorSigs.element_sources` reads these declarations. `block_return_element?` and `receiver_element?`
  answer for a name only when every owner that declares it has that source, so a name with an `untyped` owner
  (Enumerable's `select`) is not typed.
- Codegen asks the reader instead of naming iterators. The `:receiver` source is read but not consumed yet: a
  receiver-class proof has to come first, and until it exists the generated C++ does not change.
- `scripts/bc2cpp/core_facts_rbs_check.rb` pins the classification of each name.

## Consequences

- The shipped wio build's generated C++ is unchanged by this change (checked by regeneration and a path-normalized diff).
- Adding an iterator is an RBS edit, not a codegen edit.
- `flat_map` and `group_by` stay unlisted. `flat_map` flattens, and `group_by` returns a Hash.
- Enumerable's entries stay `untyped`, since RBS has no self type to name the receiver's element. Other receivers
  (Range, Struct) stay unknown until a consumer looks the receiver's own class up.
