- **RGSS native bindings are split mechanically** into a thin `mrb_get_args`
  wrapper and a frame-independent `rgss::*_direct` entry point
  (`scripts/native_binding_split.rb`, libclang-based facts in
  `scripts/native_binding_facts.py`); 51 more bindings now have direct entry
  points and bc2cpp's `NATIVE_DIRECT` table is generated from the same
  classification instead of hand-written. Covered by
  `scripts/native_binding_split_check.rb` and mrbtest's
  `mruby-rgss/test/native_direct.rb`. See
  `docs/adr/0263-native-binding-split-tooling.md`.
