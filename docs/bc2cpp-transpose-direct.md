# bc2cpp: `Array#transpose` in C

`TRANSPOSE_DIRECT` (`tools/bc2cpp/codegen_transpose_direct.rb`) puts one call
in front of the compiled core `Array#transpose` body:

```cpp
{ mrb_value bc2cpp_tr = bc2cpp_ary_transpose(M, self); if (!mrb_undef_p(bc2cpp_tr)) return bc2cpp_tr; }
```

`Array#transpose` is mruby-array-ext Ruby, not C:

```ruby
def transpose
  return [] if empty?
  column_count = nil
  self.each do |row|
    raise TypeError unless row.is_a?(Array)
    column_count ||= row.size
    raise IndexError, 'element size differs' unless column_count == row.size
  end
  Array.new(column_count) do |column_index|
    self.map {|row| row[column_index] }
  end
end
```

Compiled, every column is a `map` over the rows with a block call per element
(`row[column_index]`), and each column grows by pushes. optcarrot's
`PPU::TILE_LUT` transposes four 8 x 65,536 tables at startup: 262,144 columns
and two million block calls, about 410M instructions under callgrind. The
helper reads the row slots and fills columns allocated at their final size.

## When the helper answers

At run time, only for an exact `Array` (no subclass, no singleton class) whose
rows are all exact `Array`s of one length. For anything else it returns
`undef` before allocating anything, and the compiled body runs from the start.
That covers a subclass receiver or row, a row with its own `[]`, a non-Array
row (`TypeError`, mruby does not call `to_ary` here), and ragged rows
(`IndexError, 'element size differs'`). The body raises these errors exactly
as it did before, and no check is repeated in C.

For a qualifying receiver the result is the body's: an empty receiver gives
`[]`, empty rows give `[]`, and otherwise the result has `column_count` fresh,
unfrozen, exact Arrays of `rows` elements each. The receiver and rows are only
read, so a frozen receiver or frozen rows are fine.

## What the compiler proves first

The prologue is emitted only when everything the body would call on such a
receiver binds to mruby's own code:

- the body is still the text above (`TRANSPOSE_BODY`), read from its own
  source file on every compile;
- `empty?` and `size` are Array's own natives (`array_native_refusal`, as
  `ARRAY_NEW_BLOCK` checks `initialize`);
- `is_a?` is Kernel's only definition (`KERNEL_DIRECT`);
- `map` and `each` on an Array are core `Enumerable#collect` and `Array#each`,
  as `COLLECT_DIRECT` proves them ([bc2cpp-collect-direct.md](bc2cpp-collect-direct.md));
- `Array.new(n) { }` is mruby's own construction (`ARRAY_NEW_BLOCK`).

`row[column_index]` needs no proof: it is `OP_GETIDX`, which `vm.c` answers
itself for an exact Array and an Integer index. `column_count == row.size` is
`OP_EQ` on two Integers, also answered by the VM.

A program that defines its own `Array#transpose` is unaffected: its call
sites reach that definition, and the core body is not what runs.

## GC

`result` is allocated first and stays in the GC arena below the saved index.
Each column is allocated, filled and pushed into `result` with no allocation
in between, so no GC step can see the half-filled column. The column is
younger than any mark, so its slots need no write barrier; its store into
the pre-sized `result` takes the write barrier. The arena is cut back
after each column.

`BC2CPP_TRANSPOSE_DIRECT=0` keeps the compiled body alone.
`scripts/bc2cpp/transpose_direct_check.rb` checks the prologue and each
compile-time refusal, and compares interpreted and compiled runs for the fast
path and each run-time fallback.
