- `tools/bc2cpp/bc2cpp.rb` now sends the non-Fixnum fallback paths of
  arithmetic and ordering opcodes through its existing MONO/TYPED
  devirtualizer. Proven compiled operator methods can call directly, while
  the original fast paths and dynamic fallback remain in place. Equality
  (`EQ`) keeps its existing dispatch to preserve mruby's opcode-specific
  identity and Symbol behavior.
