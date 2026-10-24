# bc2cpp: `Array.new(n) { }` as an inlined loop

`ARRAY_NEW_BLOCK` (`tools/bc2cpp/codegen_array_new_inline.rb`) compiles
`Array.new(n) { |i| BODY }` to a counted loop that pushes the block's value
for each index. Without it the site is a by-name `new` with a heap block
(`mrb_funcall_with_block`), which runs mruby's native `Array#initialize`
(`3rd/mruby/src/array.c`, `mrb_ary_init`), which in turn yields to the
block once per index.

## When a site is inlined

The file header of `codegen_array_new_inline.rb` lists every condition. In
short:

- **The receiver is the constant `Array`.** It is written on every path to
  the send, resolves to the top-level class, and the constant is never
  rebound.
- **Array's construction is mruby's own.** Nothing replaces `new` or
  `allocate`, and `Array#initialize` is mruby's own native method. No Ruby
  source, installer or prepended module defines it, and no native
  registration other than `src/array.c`'s defines or undefines `initialize`
  on Array. That last part is read from the native sources by
  `NATIVE_OWNER_MAP` (`NativeOwnerMap.verdict` over every native source
  except mruby's `src/array.c`).
- **The shape fits.** The send has one argument (`Array.new(n, obj) { }`
  stays a call), and the block takes 0 or 1 mandatory parameters and doesn't
  forward the method's own block.

The loop reproduces what `mrb_ary_init` does with the size: `mrb_as_int`,
with the same `TypeError`; a size of 0 or less runs the block zero times;
and the same "array size too big" error. `next` gives the element and
`break v` gives the call's value.

## The native-registration test

Before `NATIVE_OWNER_MAP` was used here, the inliner refused whenever any
native source other than an `array.c` spelled `initialize` and also named
the Array class. In the closed world `random.c` matches: it registers
`Random#initialize` and, separately, uses `mrb->array_class` for Array's
random methods. So every engine site was refused
(`initialize_native_spelled`). The owner map checks the registrations
themselves (ROM method tables included), so a file that registers
`initialize` only on other classes no longer counts. With `BC2CPP_NATIVE_OWNER_MAP=0` the old spelling test
applies again.

The same proof, by method name (`array_native_refusal`), also gates the
inlined `ary.index { }` loop, since `Array#index` is native too
(`mrb_ary_index_m`).

## Switch and check

`BC2CPP_ARRAY_NEW_INLINE=0` keeps every site as a call.
`scripts/bc2cpp/array_new_block_check.rb` asserts the inlined and kept
shapes, and compares interpreted and compiled runs for a 0- and a
1-parameter block, a captured local, `next` and `break`, sizes 0, negative,
Float and non-numeric, an exception in the block, nested `Array.new`, GC in
the block, `GC.stress`, and a Fiber.
