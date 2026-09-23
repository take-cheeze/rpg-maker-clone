- **bc2cpp** `compile_method` runs its ten inlined-loop passes (times, each,
  each_index, Hash each, each_key, Range each, `&:sym`, collect, accum, sort)
  as one loop over the frozen `CodeGen::INLINE_LOOP_PASSES` table, so the
  #1909 rescue-range skip and the address registration are written once. The
  emitters share `compile_inline_block_body` (nested-block claim, body compile,
  `#error` bail-out), `inline_block_frame` and `inline_receiver_guard`. A pure
  refactor: the generated C++ of all three compiled gems is byte-identical,
  open- and closed-world.
