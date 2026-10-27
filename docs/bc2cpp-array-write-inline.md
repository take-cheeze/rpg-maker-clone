# Inline Array writes and Integer arms

The optcarrot frame loop pushes every pixel (`@output_pixels << color`),
rotates and refills the background shift register (`@bg_pixels.rotate!(8)`,
`@bg_pixels[x, 8] = lut`), stores single elements (`@bg_pixels[i] = 0`), tests
`@hclk != 255` and reads bits (`tmp[8]`, Integer#[]). bc2cpp already compiled
each of these to a direct call, but the call still went through libmruby's
general path. The build has no LTO, so `mrb_ary_push` and the other library
functions were never inlined. `rotate!` went through the owner call, which
pushes a frame so that the C body can read its argument with `mrb_get_args`.
These changes take the common case inline and leave every other case on the
call it used before.

- **ARY_WRITE_INLINE** (`ARY_WRITE_HELPERS`, tools/bc2cpp/codegen_emit.rb). The
  ARRAY_PUSH, SETIDX and ARRAY_SLICE_WRITE arms call the same-TU helpers
  `bc2cpp_ary_push`, `bc2cpp_ary_set` and `bc2cpp_ary_splice`. Each helper
  stores in place only when the library body would reduce to a store and a
  write barrier: the array is neither frozen nor sharing its buffer, and the
  store needs no growth, nil fill or element move. A splice qualifies only when
  it replaces an in-range slice with an Array of the same length that is not
  the receiver. Every other case, including frozen arrays and out-of-range
  indices, calls `mrb_ary_push` / `mrb_ary_set` / `mrb_ary_splice` as before,
  so those raise and grow the same way.
- **NATIVE_CORE_DIRECT `rotate!`** (tools/bc2cpp/native_core_direct.rb). Two
  hand entries, `rotate!` and `rotate!(n)` with a fixnum `n`, pin
  `ary_rotate_bang` and `rev`. The call is a mirror,
  `bc2cpp_ary_rotate_bang`. The exact-Array arm sits in front of the owner
  call, which stays the else for every other receiver or argument.
- **NEQ_INTEGER_PAIR** (tools/bc2cpp/codegen_native_send.rb). The bytecode of
  `!=` is `!(self == other)`, and OP_EQ compares two Integers in place. Before
  this change, `!mrb_equal` sent `Integer#==` for every pair that was not
  identical, so that pair is now compared inline before `mrb_equal`.
- **POLY_INTEGER_TAG** (`compile_poly_small_n`,
  tools/bc2cpp/codegen_ivar_poly.rb). In a POLY_SMALL_N chain that has an
  Integer arm, the receiver's class is read once, as `M->integer_class` for an
  Integer (an immediate has no singleton class) and as `mrb_obj_class`
  otherwise. The Integer arm is tested first. The shared `[]` chain in
  `bc2cpp_getidx_slow` uses this for the probe's Ruby Integer#[]. Set
  `BC2CPP_POLY_INTEGER_TAG=0` to keep the old per-arm `mrb_obj_class` reads.

`MRBC=path/to/mrbc ruby scripts/bc2cpp/array_write_inline_check.rb` checks the
generated shape of each site. It also compares interpreted and compiled runs
over the fallbacks: frozen and shared receivers, negative and out-of-range
indices, resizing and self splices, `rotate!` counts of every sign, Array
subclasses, and `!=` across Integer, Float, nil and String.
