- **bc2cpp inlines block loops inside a `rescue` range** (ADR 0376): the try body
  that `mrb_protect_error` runs now gets the same inliner passes as the method
  body, restricted to its own range and refusing a `return` through the block,
  so `ary.each { }`, `times`, `Hash#each` and the rest no longer fall back to an
  RProc plus `mrb_funcall_with_block` when a method-level `rescue` wraps them. A
  2..8 parameter `each` block over a proven Array now inlines too, spreading
  each Array row over its parameters as `OP_ENTER` does. In the hot-only
  firmware builds nine literal-block sites in `Scene::Map` close (seven
  methods) plus `Game::Interpreter#key_input_result`; the full world loses 22
  `BLOCK_FALLBACK` markers. `BC2CPP_RESCUE_INLINE_BLOCKS=0` and
  `BC2CPP_EACH_SPREAD=0` restore the old output. Covered by
  `scripts/bc2cpp_rescue_inline_block_check.rb` (compiled against interpreted
  on real mruby) and its mutation check.
