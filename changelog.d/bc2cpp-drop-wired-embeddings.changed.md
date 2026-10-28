- **bc2cpp embeds every class its safety checks accept.** The hand-kept
  `BC2CPP_WIRED_EMBEDDINGS` list in `tools/bc2cpp/compiled_gems.rb`, which an
  engine class had to be on before its ivars could live in compiled slots, is
  gone; `drop_unsafe_embeddings` and `select_embeddings` alone decide. A class
  that inherits from a built-in type (an Exception, Array or Struct subclass)
  is now refused there, since `mrb_data_init` would overwrite that type's
  fields. The core half of the split registration holds the core owners only.
