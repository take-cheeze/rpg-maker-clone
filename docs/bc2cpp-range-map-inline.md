# bc2cpp: `(a..b).map { }` as an inlined loop

`RANGE_MAP_INLINE` (`recognize_range_map_regions` in `tools/bc2cpp/codegen_loop_regions.rb`,
`emit_range_map_inline` in `tools/bc2cpp/codegen_loop_inline.rb`) compiles `(a..b).map { |i| BODY }` and
`(a...b).map { |i| BODY }` to a counted loop that pushes the block's value for each `i`. Without it the site calls the
compiled `Enumerable#collect`, which runs `Range#each` and, for every element, collects `|*val|` into an Array and
dispatches `block.call(*val)`: an allocation and a funcall per element.

## When a site is inlined

- **The receiver is a Range literal of two Integer literals.** The register's dominating writer is a
  `RANGE_INC`/`RANGE_EXC` whose operands are Integer literals smaller than 2**30 in magnitude, so the loop's
  Integer header never refuses and the counter stays a Fixnum on every target, the 32-bit ones included. A computed
  or Float bound keeps the call.
- **`map` on a Range is mruby's own.** BLOCK_CORE_DIRECT's proof (`block_core_target`) must find that `map` on a
  Range resolves to core `Enumerable#collect` and `each` to core `Range#each`: no program definition on the
  chain, no native registration, prepend, outside definer or dynamic installer. Those are the bodies the loop
  follows (`3rd/mruby/mrblib/enum.rb`, `range.rb`'s Integer path): `ary.push(block.call(i))` for each `i`.
- **The block takes one plain parameter.**

`next v` gives the element, `break v` the call's value, and a `return` leaves the method.

## Inside a BLOCK_FALLBACK body

A block nested in an inlined loop is compiled as a standalone cfunc (BLOCK_FALLBACK). A Range map in such a body is
inlined there too, before the body's own nested pass would make it one more cfunc called per element. That is
`PPU::TILE_LUT`'s shape: the outer Array map is inlined into the method, the `(0..7).map` body becomes a cfunc, and
its `(0...0x10000).map` now runs as a loop inside that cfunc.

The inlined block reads the host function's own registers at level 0, as in a method, and the frames the host
captured at level 1 and further out, through the host's captured-upvar parameters (`inline_host_upvar_name`; a
write roots the value as the host's own SETUPVAR does). A block that nests another block or lambda, or that
returns from the method, stays a nested cfunc.

## Switch and check

`BC2CPP_RANGE_MAP_INLINE=0` keeps every site as a call. `scripts/bc2cpp/range_map_inline_check.rb` asserts the
inlined and kept shapes and compares interpreted and compiled runs for inclusive, exclusive, empty and negative
ranges, `next`, `break`, `return`, a captured local, an exception in the block, GC in the block, the nested
BLOCK_FALLBACK shape (reads and writes of outer locals), `GC.stress`, and a Fiber.
