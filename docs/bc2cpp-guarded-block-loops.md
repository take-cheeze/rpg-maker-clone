# bc2cpp: guarded block loops

The block loops of `codegen_loop_inline.rb` (`each`, `map`, `select`,
`reduce`, `times`, ...) replace a block send with a loop in the method's own
`_impl`, with no `RProc`, no by-name send and no `yield`. When the receiver's
class is proven, the loop replaces the send outright. When it isn't,
`GUARDED_BLOCK_INLINE` (`codegen_guarded_block_inline.rb`) emits the loop
behind a run-time exact-class test (`mrb_array_p(r) && class == Array`), and
the ordinary send stays behind it as the else. Every other receiver (a
subclass, a Hash, nil, a user class) dispatches exactly as before.

## The arm gate

A guarded loop is sound only if it does what the send would do for that
class. Normally the proof is that `BLOCK_CORE_DIRECT` has an arm for the
same send: the class answers the name with a compiled core body, and no
project definition, native, prepend, mixin or dynamic installer gets in the
way. Two cases have no compiled body to name, so they carry the rest of that
proof themselves (`guarded_plain_chain_arm?`):

- **`GUARDED_PLAIN_ARM`:** a zero-argument send on Array or Hash whose core
  Ruby definition is on the class itself (mruby's `Array#each` is not
  compiled, but the loop is the same iteration).
- **`GUARDED_FOLD_ARM`:** `reduce(init) { }` / `inject(init) { }` on Array.
  The first core definer on Array's chain is `Enumerable#inject`, which
  isn't compiled because it builds a lambda for the `inject(:sym)` form. The
  fold loop reproduces what `inject` does with an initial value and a block.
- **`GUARDED_NATIVE_ARM`:** `index { }` on Array. `Array#index` is mruby's
  native `mrb_ary_index_m`, the same loop, and nothing else may define
  `index` on Array: no Ruby definition, prepend, installer, or native
  registration outside mruby's `src/array.c` (`array_native_refusal`, the
  proof `Array.new` inlining uses). The proven-Array loop needs the same
  proof.

## A fold's initial value

`Enumerable#inject` treats a Symbol last argument as the operator and
ignores the block: `[1, 2, 3].reduce(:+) { |m, x| m * x }` is 6. So a fold,
proven or guarded, becomes a loop only when its initial value is proven not
to be a Symbol (`fold_init_not_symbol?`, from the flow-proven class set at
the send). An unproven initial value keeps the send.

## Switch and check

`BC2CPP_GUARDED_BLOCK_INLINE=0` turns the guarded loops off.
`scripts/bc2cpp/block_iterator_direct_check.rb` asserts the guarded
`times`, `reduce` and `index` shapes, the refused Symbol and unproven initial
values, and that a program `Array#index` withdraws the index loops. It also
compares interpreted and compiled runs over Arrays (frozen included), a
Range, a Hash and a user Enumerable.
