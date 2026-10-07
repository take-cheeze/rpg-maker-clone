- **bc2cpp** native direct arms (`x=`, `y=`, `z=`, `flash`, `Bitmap.new`, ...) no longer test an
  argument for Integer and fall back to a by-name send: when the closed world proves the name
  reaches the RGSS native, the call site converts `:int`/`:float` arguments with
  `mrb_as_int`/`mrb_as_float`, which is exactly what the binding's `mrb_get_args "i"`/`"f"` do, in
  argument order. This also fixes the order two `:float` arguments (`_transition_alpha`,
  `Color.new`) were converted in, which was unspecified. `BC2CPP_NATIVE_PARAM_UNBOX=0` restores
  the old gate; see ADR 0372 and `scripts/bc2cpp_native_param_unbox_check.rb`.
