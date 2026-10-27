# Reading the receiver's class inline (CLASS_READ_INLINE)

A devirtualized call in the compiled C++ is usually guarded by an exact-class test. MONO_EMBED_GUARD, TYPED,
IVAR_ACCESSOR, POLY_SMALL_N, NATIVE_OWNER_MAP, the RGSS native wrappers, setter pools, declared-return guards and
CORE_SELF_NATIVE all test the receiver. INHERITED_GUARD, POLY_INTEGER_TAG, USER_RECEIVER_CASES, interface tables and
subtree dispatch read its class once into a local first. Every one of them used to call mruby's `mrb_obj_class`.

`mrb_obj_class` is `mrb_class_real(mrb_class(mrb, v))`. Both functions are out of line in `src/class.c`. For a heap
object, `mrb_class` returns the object's class pointer `c`. `mrb_class_real` then skips singleton classes
(`MRB_TT_SCLASS`) and iclasses (`MRB_TT_ICLASS`) up the `super` chain. Any other class it returns unchanged.

## What changes

The prelude of every generated file defines two inline helpers, and the code generator emits nothing else for a
guard or a hoisted class read (`CodeGen#exact_class_guard` and `CodeGen#obj_class_expr` in
`tools/bc2cpp/codegen_send.rb`):

```cpp
static inline struct RClass* bc2cpp_obj_class(mrb_state* M, mrb_value v) {
  if (!mrb_immediate_p(v)) {
    struct RClass* c = mrb_obj_ptr(v)->c;
    if (c->tt == MRB_TT_CLASS) return c;
  }
  return mrb_obj_class(M, v);
}
static inline bool bc2cpp_class_is(mrb_state* M, mrb_value v, struct RClass* cls) {
  if (!mrb_immediate_p(v) && mrb_obj_ptr(v)->c == cls) return true;
  return cls == bc2cpp_obj_class(M, v);
}
```

- `bc2cpp_obj_class` returns exactly what `mrb_obj_class` returns. A heap object whose class pointer is a plain class
  is its own answer, because `mrb_class_real` would return it unchanged. Everything else still makes the call: an
  immediate (Integer, Symbol, nil, true, false, Float), an object with a singleton class (`extend`, `def obj.x`,
  `singleton_class`), and any other class type.
- `bc2cpp_class_is(M, v, cls)` is `cls == mrb_obj_class(M, v)`. Its first test accepts an object whose class pointer
  is `cls` itself. A miss falls through to `bc2cpp_obj_class`. In a POLY_SMALL_N chain, the arm the object belongs to
  then costs a pointer compare, and every earlier arm costs the same compare plus the `tt` test.

`BC2CPP_CLASS_READ_INLINE=0` emits both helpers as plain `mrb_obj_class` calls, for comparison. The generated call
sites are the same text either way.

## Why it is sound

`bc2cpp_obj_class` follows `mrb_class_real` directly: it returns early only for the class type that function
returns unchanged.

`bc2cpp_class_is`'s first test gives the same answer as `mrb_obj_class` only when `cls` is a plain class (or null,
which no live object's class pointer equals). If `cls` were a singleton class, the object whose `c` is `cls` would
pass the test, while `mrb_obj_class` would say that object's class is the real class above it. Every `cls` the
generator passes is a plain class:

- an owner-cache entry (`bc2cpp_owner_class_N`) is the constant named by a closed-world `class X` statement, and
  `mrb_vm_define_class` raises unless an existing constant is an `MRB_TT_CLASS`. A later reassignment of the
  constant is outside the cache's contract already (OWNER_CLASS_CACHE, `docs/bc2cpp-constant-lookup.md`);
- the core fields (`M->array_class`, ...) and the RGSS accessors (`rgss::native_bitmap_class()`, ...) are
  classes made with `mrb_define_class`;
- an iclass is never a Ruby value, so it is never a constant either.

A module would be harmless too, though a guard never names one (MODULE_OWNER_EXCLUSION in
`codegen_ivar_poly.rb`): no object's class pointer is a module, so the first test never accepts one.

A prepended module does not change the result. `prepend` moves the class's methods to an origin iclass. The class
object stays `MRB_TT_CLASS`, and its instances keep it as their class pointer. So `mrb_obj_class` and both helpers
return the class itself.

Which sites are guarded, and what each arm dispatches to, does not change.

## Check

`MRBC=path/to/mrbc ruby scripts/bc2cpp/class_read_inline_check.rb` checks:

- the generated code: both helpers in the prelude, the kill switch, and that MONO_EMBED_GUARD, TYPED,
  NATIVE_OWNER_MAP, IVAR_ACCESSOR, POLY_SMALL_N, INHERITED_GUARD, POLY_INTEGER_TAG and USER_RECEIVER_CASES sites use
  them, with no `mrb_obj_class` call left in a compiled method;
- a fixture run interpreted and compiled, with the same output at every one of those sites for plain instances,
  subclass instances, objects with a singleton class, objects extended by a module, instances of a class with a
  prepended module (also extended), immediates and objects of other classes.

## Effect on optcarrot

Measured with callgrind on the probe (Lan_Master, `BC2CPP_SHARDS=4`). Per-frame figures are the 21-frame run minus
the 1-frame run, divided by 20. The base is ATTR_READER_INLINE (`claude/bc2cpp-attr-reader-inline-w7k3`, which
this builds on). The checksum is 59662 at 180 frames in both builds.

| | ATTR_READER_INLINE | CLASS_READ_INLINE | delta |
|---|---|---|---|
| frame loop | 23.667 M | 23.490 M | −177.1 K (−0.75 %) |
| `mrb_obj_class` (with its inlined `mrb_class`) | 202.6 K | 0 | −202.6 K |
| `APU::Mixer#sample` (five-arm POLY_SMALL_N chains, ~12 K tests a frame) | | | +19.1 K |
| everything else, net (the other guard sites) | | | +6.4 K |

Startup (the 1-frame run) falls by 0.96 M instructions (−0.09 %). Against master `01e9778e`, the two changes
together take the frame loop from 23.835 M to 23.490 M (−1.45 %).

The pointer-compare first test in `bc2cpp_class_is` is worth about 59 K a frame on its own: with only
`bc2cpp_obj_class` (a guard written `cls == bc2cpp_obj_class(M, v)`), the frame loop was 23.547 M, and `CPU#run`
(ATTR_READER_INLINE's `@conf.loglevel` guard) paid two more instructions per test for the `tt` load.
