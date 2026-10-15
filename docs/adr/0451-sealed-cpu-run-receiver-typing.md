# 0451. Sealed-build CPU#run needs receiver typing before it can compile

Date: 2026-10-15

## Status

Proposed

## Context

The closed-world (sealed) build of optcarrot runs about 13 fps, the same as the mruby interpreter, because
`Optcarrot::CPU#run` stays interpreted. The default bc2cpp build runs about 35 fps. The sealed build keeps
`CPU#run` interpreted because the yield analysis (yield_reach.rb) cannot prove it yield-free.

Earlier work resolved the dispatch table (SymbolFlow, ADR 0450) and the parameter-named sends of the op
methods. Two blockers remained:

1. **Native callback edges are name-level.** A native node reaches every Ruby method whose name a native
   source can funcall (the opaque edge). A call of `[]` therefore reaches every `[]` registration, including
   `Method#[]` (which runs Ruby code through `mrb_vm_exec`) and the class-level `[]` of `Hash`/`Array`
   (which reaches `initialize`, and from there `Parser#initialize` and `parse_option`, which are not
   yield-free).

2. **The `[]` sends on the Fiber path have receivers the analysis cannot type.** In `CPU#fetch`, `@fetch[addr][addr]`
   calls `Method#[]` on a Method object stored in an array. The Method objects are the mapping targets built by
   `add_mappings` (`method(:peek_ram)`, ...). Typing the receiver needs a finite universe of Method objects
   (`method(:x)` literals flowing through parameters, the `@peeks[peek] ||= peek` cache and the `@fetch[a] = peek`
   stores), and the array index `addr` must be provably an Integer, which depends on the CPU's address
   registers (`@_pc`, `@addr`, `@data`), each with many writes.

Measurements from the sealed build's dump (scratchpad spike, not committed):

- Native registrations that map to a named class: 207 of 304 (Stage 1 class map).
- Operator sends reachable from the Fiber whose receiver type is known: 10 of 174 (`|` 4/74, `!=` 2/62,
  `each` 4/19, `[]` 0/2, `!` 0/16).
- ARRAY literal sites that escape analysis proves closed: 218 of 288. `@sp_ram` escapes through
  `sprite_dma`. `@store` is written with Method objects (`cpu.rb:121`), so its element type is not `NilClass`.
- Instance variables with a type from their writes: 32 of 197.

Earlier element-type claims were unsound: an element type taken from a literal alone ignores later writes
(`@store[a] = poke || @poke_nop`) and escapes. Element types are trusted only for sites the escape analysis
proves closed.

## Decision

Keep the sealed build's `CPU#run` interpreted for now. Do not wire the spike's types into the native callback
filter: at 10 of 174 receivers the filter would not change which edges reach `initialize`, so the sealed build
would stay refused. Pursue the following only if the sealed build becomes a priority:

- A Method-object universe. Type `method(:x)` (and `obj.method(:x)`) as a Method value carrying the set of
  names. Flow it through parameters (call sites), hash values and array elements, gated by the same closedness
  rule. A `[]` or `call` whose receiver is a closed Method universe then becomes calls of those names, like the
  dispatch-table universe in yield_reach.rb.
- Integer typing of the CPU address registers, so the array index in `@fetch[addr]` is provably an Integer.
  This needs the writes of `@_pc`, `@addr` and `@data`, which depend on memory reads and ALU results.
- Each step carries a soundness condition, and the wiring into yield_reach.rb is a separate change.

The default bc2cpp build is the performance path for now.

## Consequences

- The sealed build stays at about 13 fps for optcarrot. Nothing in the default build changes.
- The analysis spike (type rules, escape analysis, native class map) is kept outside the repository. Promoting
  it needs its own ADR and a soundness review, because each rule depends on a closed-world assumption.
- Native callbacks remain name-level. Any change that narrows them must handle receiver classes, not just
  names, since `[]` collides across classes.
- Revisit this decision if the sealed build becomes a priority, or if the native callback model gains receiver
  classes from another source.
