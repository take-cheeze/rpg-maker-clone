- **bc2cpp: `ary.index { |x| ... }` runs as an inlined loop.** On a proven
  Array it is a plain loop, and on an unproven receiver a guarded one (an
  exact-Array test in front of the send). `Array#index` is mruby's native
  `mrb_ary_index_m`, so the loop is used only when nothing else defines `index`
  on Array: no Ruby definition, prepend, installer or other native registration
  (the native-registration proof `Array.new` inlining already used, now shared
  by name).
