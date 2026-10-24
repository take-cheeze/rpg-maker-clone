# bc2cpp: `&expr` block sends as direct calls

A send that passes its block as an expression — `items.reject(&:dead?)`,
`all.each(&block)`, `map_items(&method(:label))` — has no `BLOCK`
instruction: the block value is already in the register after the arguments
when the `SENDB`/`SSENDB` runs. bc2cpp used to emit every such site
(`EXPLICIT_BLOCK_ARG`) as `mrb_funcall_with_block`, a by-name dispatch through
a VM frame even when the receiver's method is compiled code.

`EXPLICIT_BLOCK_ARG_DIRECT` (`emit_explicit_block_arg_direct` in
`tools/bc2cpp/codegen_block_fallback.rb`) sends a fixed-arity site through the
same resolution as a literal block (`compile_direct_block_send`, the
ARG_SHAPES_BLOCK path): compiled callees with a block slot, the
`BLOCK_CORE_DIRECT` arms over mruby's compiled core bodies (`Array#each`,
`Enumerable#reject`, ...), and the closed world's owner call in the else. The
site keeps `mrb_funcall_with_block` when that resolution does not end in a
direct call carrying the block, and always for a splat (`f(*a, &b)`).

## The block value

The callee's `_impl` receives the block exactly as the VM would hand it on:
before any arm runs, the site applies `ensure_block` (`src/vm.c`):

```c
if (!mrb_nil_p(blk) && !mrb_proc_p(blk)) blk = mrb_type_convert(M, blk, MRB_TT_PROC, to_proc);
```

So `&nil` is no block, a Proc passes as is, and a Symbol, a Method or an
object with its own `#to_proc` becomes a Proc once. A value with no `#to_proc`
raises the same `TypeError` at the site. The by-name else gets the converted
value too; converting a Proc again is a no-op.

## The guarded else

When a Ruby class defines the name (`Ring#each`) and the receiver may be an
outside class (`@a.each(&b)` on an Array), the chain guards on the Ruby
definer and its else must reach the outside one. That else is the owner call
over every class answering the name (`OutsideOwnerCall`). Before this change
the pattern that swaps a lifted `bc2cpp_nomethod` else for the owner call
missed the marker's ` @ site` suffix, so such a block send kept a proven
NoMethodError; literal-block sites hit the same gap.

## Switch and check

`BC2CPP_EXPLICIT_BLOCK_ARG_DIRECT=0` keeps every `&expr` site on
`mrb_funcall_with_block`. `scripts/bc2cpp/explicit_block_arg_direct_check.rb`
compiles `&:sym`, `&method(:x)`, a user `#to_proc`, `&nil`, a positional
argument in front of the block, a forwarded `&blk`, a guarded `each` over an
Array and a non-convertible value, and compares interpreted and compiled runs
on two VMs.

## Effect on the closed world

The closed world (`scripts/bc2cpp/closed_build.bash`, all four compiled gems):

| Measure | Before | After |
| --- | ---: | ---: |
| `&expr` sites calling compiled code with the block | 0 | 25 |
| `&expr` sites on `mrb_funcall_with_block` only | 30 | 5 |
| literal-block `mrb_funcall_with_block` calls | 349 | 283 |
| owner calls carrying a literal block | 0 | 83 |
| `mrb_funcall_with_block` calls, all | 382 | 311 |
| `bc2cpp_nomethod` sites | 4153 | 4153 |

20 of the converted `&expr` sites keep an `mrb_funcall_with_block` as the
else of their arms: for a receiver no arm names, and inside a Fiber (the
`M->c == M->root_c` test of a core arm), where the callee needs a real VM
frame.
