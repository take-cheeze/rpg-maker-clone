# bc2cpp: `map` on an exact Array without Enumerable#collect's splats

`COLLECT_DIRECT` (`tools/bc2cpp/codegen_collect_direct.rb`) changes one
`BLOCK_CORE_DIRECT` arm. When a literal-block `map`/`collect` reaches an exact
`Array`, the arm calls `bc2cpp_ary_collect(M, recv, blk)` instead of the
compiled `Enumerable#collect`.

mruby's `Enumerable#collect` is

```ruby
ary = []
self.each {|*val| ary.push(block.call(*val))}
ary
```

so every element builds the rest-parameter Array, splats it into a second
Array for `block.call(*val)`, and runs through an extra compiled block. For
optcarrot's `PPU::TILE_LUT`, `Array#transpose` alone mapped two million
elements this way at startup.

## Why the helper is the same loop

`Array#each` is

```ruby
idx = 0
while idx < length
  yield self[idx]
  idx += 1
end
```

On an exact Array, `self[idx]` with `idx < length` is the slot itself, and
`block.call(*[x])` passes `x` as the one argument, which is the same call as
`yield x` (a non-lambda block spreads an Array argument the same way in both).
The helper re-reads the length and the slot on every pass, so a block that
grows or shrinks the receiver sees what the Ruby loop would. `break` from the
block unwinds through the helper exactly as it unwinds through the compiled
`Enumerable#collect` (the site's try block catches it). The result is
pre-sized to the receiver's length; capacity is not observable.

The arm is used only when:

- the `BLOCK_CORE_DIRECT` proof already names core `Enumerable#collect` for
  `map` on `Array`, and finds core `Array#each` for `each`;
- no program definition and no runtime installer names `length` or `[]` on
  Array's chain (the helper reads the `RArray` directly);
- the source text of both core definitions, read from their own files on every
  compile, is still the text above (`COLLECT_DIRECT_BODIES`).

## The per-element yield

`COLLECT_YIELD_HOIST` keeps the per-element step of the loop short.
`bc2cpp_yield_argv` tests whether the block is a compiled block on every
call. Inside the helper, `blk` cannot change, so the helper makes that test
once before the loop and then calls the block's direct entry for each element.
Any other block goes through `mrb_yield_argv`, the same fallback
`bc2cpp_yield_argv` uses.

The GC arena also stays small. `bc2cpp_yield_argv` restored the arena and then
re-protected each result, so a 65,536-element map left 65,536 arena slots. The
helper now saves the arena after it allocates the result Array. It stores each
result into the Array and only then cuts the arena back. Every value is
therefore held by the arena or by the Array.

The result Array has no other reference until the helper returns, so it is
never shared or frozen. A store into spare capacity is a plain slot write plus
the write barrier; anything else goes through `mrb_ary_push`.

The arm keeps the original guards (the exact-class test and, where the block
may yield, the root-context test), so a subclass instance or a Fiber still
takes the by-name path. `BC2CPP_COLLECT_DIRECT=0` keeps the
`Enumerable#collect` call.

`scripts/bc2cpp/collect_direct_check.rb` checks the helper's shape: the block
test comes before the loop, and the arena is cut back after each store. It
also compares interpreted and compiled runs, including a `GC.stress` map whose
block allocates. The startup also gains from `NEQ_OP_EQ` and `POLY_INTEGER_TAG`
([bc2cpp-array-write-inline.md](bc2cpp-array-write-inline.md)): the TILE_LUT
loop's `x != 0` and the probe's `Integer#[]` shim, so the check keeps
behaviour cases for both.
