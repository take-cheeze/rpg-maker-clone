- **bc2cpp: `&expr` block sends call compiled code directly.** A fixed-arity
  send that passes its block as an expression (`reject(&:dead?)`,
  `each(&block)`, `map(&method(:x))`) now takes the literal-block resolution
  (compiled callees, the core block arms, the owner call) instead of always
  dispatching through `mrb_funcall_with_block`; the block is converted with
  `#to_proc` first, as `OP_SENDB` does. In the closed world 25 of 30 such
  sites become direct and `mrb_funcall_with_block` calls drop from 382 to 311.
  `BC2CPP_EXPLICIT_BLOCK_ARG_DIRECT=0` restores the earlier output. See
  `docs/bc2cpp-explicit-block-args.md`; covered by
  `scripts/bc2cpp/explicit_block_arg_direct_check.rb`.
