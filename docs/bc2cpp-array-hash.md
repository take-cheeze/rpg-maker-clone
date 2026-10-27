# bc2cpp: `hash` of an Array of Fixnums without by-name sends

`ARRAY_HASH_FIXNUM` (`tools/bc2cpp/codegen_array_hash.rb`) adds a native
fast path at the start of the compiled `Enumerable#hash` body. The fast path
runs when `self` is an exact `Array` and every element is a Fixnum.

mruby's Hash calls `#hash` on an Array key through `mrb_funcall`, and that
call reaches `Enumerable#hash` (`mrblib/enum.rb`):

```ruby
def hash
  if __method_recursive?(:hash)
    return 0
  end
  h = 12347
  i = 0
  self.each do |e|
    h = __update_hash(h, i, e.hash)
    i += 1
  end
  h
end
```

Compiled, every element made two by-name sends (`e.hash` and
`__update_hash`). On top of that, each call made one by-name send
(`__method_recursive?`) and one `Array#each` with a block. optcarrot's
`PPU#setup_lut` looks up `entries[[io_addr, attr_shift]]` about 98,000 times
at startup, and each lookup hashes a two-element key.

## Why the value is the same

Each send reaches a C function, and the fast path computes what that function
computes:

- `__method_recursive?(:hash)` is kernel.c's `mrb_obj_method_recursive_p`.
  It scans the call frames below its own frame and its caller's frame for
  `:hash` on the same object. Called from the compiled body, its own frame sits
  one above the current frame. The fast path therefore scans from
  `M->c->ci - 1` down, and returns 0 on a match, as the Ruby body does.
- `e.hash` on a Fixnum is numeric.c's `int_hash`:
  `mrb_byte_hash` over the `mrb_int`.
- `__update_hash(h, i, hv)` is enum.c's `enum_update_hash`:
  `h ^= ((uint32_t)hv << (i % 16))` on `mrb_int`s.

The fast path writes the same C expressions with the same types, so a 32-bit
`mrb_int` truncates and wraps exactly as those functions do. It checks the
elements before it hashes anything. The loop runs no Ruby, so the receiver
cannot change while it runs. A receiver that fails the checks runs the
original body. That covers a subclass instance, an Array with a singleton
class, and any element that is not a Fixnum (Float, bignum, String, nested
Array, ...).

## When it is used

The fast path is used only when all of the following hold:

- the body is core `Enumerable#hash` and its source text is the text above,
  read from `enum.rb` on every compile;
- the program's world (the closed world, or the program world a core compile
  reads) shows these names are not redefined: `Integer#hash`, `__update_hash`
  and `__method_recursive?` reach their native registrations from `Integer`
  and from `Array` (`builtin_class_send_safe?`);
- no runtime installer or symbol-installed name covers `hash`,
  `__update_hash`, `__method_recursive?` or `each`;
- `Array#each` is core and reads `length` and `[]` natively, the same
  condition `COLLECT_DIRECT` uses.

The wrapper's existing guards still run first: the Fiber/yield test and
`bc2cpp_core_each_is_builtin`. That helper now interns `each` once per
`mrb_state`, not on every call.

`BC2CPP_ARRAY_HASH=0` keeps the plain body.

## Checks

`scripts/bc2cpp/array_hash_check.rb` checks the generated code: the prologue
and the helper are present, and a program `Integer#hash`, a program
`__update_hash` or the env switch each turn the fast path off. It also
registers the compiled `Enumerable` methods and compares interpreted and
compiled runs. The cases cover:

- `hash` values for empty, negative, wide and `2**40` Fixnum Arrays;
- mixed, nested, Float, bignum and subclass Arrays;
- an Array that contains itself;
- a recursion reached through an element's own `hash`;
- Hash lookups and iteration order with Array keys.

Breaking the initial value or the recursion scan each fails this comparison.
