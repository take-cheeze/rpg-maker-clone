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

The helper always yields, so it covers only the `block` arm of
`Enumerable#collect`. A block argument that is not the site's own literal
block can be nil (`map(&nil)`, or an absent `&b` passed on), and there the
call is `mrb_nil_p(blk) ? Enumerable_collect_impl(...) : bc2cpp_ary_collect(...)`:
the compiled body's `return to_enum(:collect) unless block` answers nil with
the Enumerator the interpreter returns.

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

## Range map and each

`RANGE_COLLECT_DIRECT` does the same for an exact `Range`. A literal-block
`map`/`collect` or `each` whose `BLOCK_CORE_DIRECT` arm names core
`Enumerable#collect` or core `Range#each` calls

```cpp
r = bc2cpp_range_int_p(M, r) ? bc2cpp_range_collect(M, r, blk) : Enumerable_collect_impl(M, r, blk);
r = bc2cpp_range_int_p(M, r) ? bc2cpp_range_each(M, r, blk) : Range_each_impl(M, r, blk);
```

These are the sites the inlined Range loops leave alone: bounds that are not
literals (`(0...n).map`, a Range argument), or a Range loop inside a block
that is itself inlined into an outer loop (optcarrot's
`[1, 6].map { |s| (0..0x7fff).map { |bits| ... } }`). Without the helper,
each element went through `Range#each`, `Enumerable#collect`'s `|*val|`
block and `block.call(*val)`: two Arrays and two block calls per element.

`Range#each`'s Integer branch is

```ruby
lim = last
lim += 1 unless exclude_end?
i = val
while i < lim
  block.call(i)
  i += 1
end
```

and the helpers run the same `i` from `begin` through `end` (or below it), with
the bounds and `exclude_end?` read once. `bc2cpp_range_int_p` takes the helper
only when both bounds are Integers. Any other Range takes the compiled body:
Float, String or bigint bounds, an endless Range, and an inclusive end at
`MRB_INT_MAX` (where the Ruby body's `lim += 1` leaves `mrb_int` and its loop
is not this one).

The block is always the site's own literal block, so it is never nil or a
lambda and `block.call(i)` is the plain yield the helper makes; a site with
any other block expression keeps the compiled call. Neither helper keeps the
block, so they take the frame-local block (`docs/bc2cpp-stack-blocks.md`)
where the site built one. `break`, `next`, a method `return` and exceptions
leave the helper exactly as they leave the compiled bodies.

The arm is used only when, besides the `BLOCK_CORE_DIRECT` proof:

- `Range#each` begins with the text above, through its Integer branch
  (`COLLECT_DIRECT_PREFIXES`, read from `range.rb` on every compile);
- the names that branch calls (`begin`, `end`, `kind_of?`, `nil?`,
  `exclude_end?`, `call`) have no program Ruby definition on any owner, no
  dynamic installer or outside definer, no other core Ruby definition, and no
  native registration on the classes they resolve through other than mruby's
  own `src/*.c` (`range_each_core?`).

The exact-class and root-context tests of the arm stay, so a Range subclass
and a Fiber still dispatch by name. `BC2CPP_RANGE_COLLECT_DIRECT=0` (or
`BC2CPP_COLLECT_DIRECT=0`) keeps the compiled calls.
`scripts/bc2cpp/range_collect_direct_check.rb` asserts the arms, the
helper's shape and the withdrawals, and compares interpreted and compiled runs
over inclusive, exclusive, empty, reversed, negative, `MRB_INT_MAX`-edge,
Float, String, bigint, endless and subclass Ranges, with `break`, `next`,
`return`, an exception, block arities, outer locals, `GC.stress` and a Fiber.
