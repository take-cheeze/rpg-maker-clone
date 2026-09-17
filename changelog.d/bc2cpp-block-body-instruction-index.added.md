- `tools/bc2cpp/bc2cpp.rb` now gives an INLINED block body's own
  instructions a real instruction index, so the two static proofs that are
  gated on one -- `GETIDX_STATIC_RECEIVER_SUPPORT`'s
  `static_indexable_class` (the `[]`/`[]=` static-receiver-class proof) and
  `FIXNUM_OPERAND_PROOF`'s `proven_fixnum_operand?`/`proven_fixnum_pair?`
  -- run inside `.each`/`.times`/`.each_index`/`.each_key`/
  `.each_with_index`/Range-`.each`/`map`/`select`/`reduce`/`sort_by`
  loop bodies for the first time, instead of declining unconditionally.
  Total `mrb_funcall`/`mrb_funcall_with_block` call sites in the real
  shipped whole-program build **14628 -> 14616**: `:[]` 1736 -> 1726,
  `:[]=` 296 -> 294.

  **What the gap actually was.** Both proofs start from a backward scan
  over `irep.instructions` beginning at this instruction's own position,
  and both refuse outright when handed no position (`static_indexable_
  class`'s `return nil unless owner_def && idx`, `proven_fixnum_operand?`'s
  `return false unless irep && idx && reg && owner_def`). Every real caller
  had a position to give them -- `compile_method`'s own top-level
  `irep.instructions.each_with_index`, `emit_rescue_try_body`'s extracted
  try-body loop, and (worth stating plainly, since it was the first
  suspect) `emit_proc_fallback_fn`, which has always passed a real `idx`
  for a `BLOCK_FALLBACK`/`LAMBDA_FALLBACK` cfunc body. The one caller that
  did not was `compile_block_body_insn`, whose shared `else` branch
  delegated an inlined loop body's instructions to `compile_insn` as
  `compile_insn(shifted, block_irep, owner_def, nil)`.

  That `nil` was not an oversight, and threading the loop counter alone
  would have been wrong. An inlined block body is spliced straight into
  its ENCLOSING method's C++ function, so the two frames' `r<n>` variables
  have to stay disjoint: the delegation rewrites every `R<n>` in
  `insn.args` to `R<n + offset>` (`offset` = the enclosing irep's own
  `nregs`) before handing the instruction on. The emitted C++ must say
  those shifted numbers; a backward scan over `block_irep.instructions`
  must not -- it matches a bare `R<n>` against the block irep's OWN,
  un-shifted instruction text. Handing a real index without accounting for
  the shift would have made both proofs scan for a register that does not
  exist in that stream, or (worse, for `static_indexable_class`, whose
  `Array`/`Hash` arms emit a raising `mrb_array_p`/`mrb_hash_p` assertion)
  claim a fact about the wrong register.

  **The fix** is therefore two facts instead of one. `compile_insn` gains a
  `reg_offset` parameter (0 for every other caller, so the identity),
  `compile_block_body_insn` gains an `idx:` keyword, and the delegation
  becomes `compile_insn(shifted, block_irep, owner_def, idx, offset)`. A
  new one-line helper, `unshift_proof_reg`, subtracts the shift at exactly
  the 12 points where a register number reaches a proof rather than the
  generated C++ -- the eight `proven_fixnum_operand?`/`proven_fixnum_pair?`
  call sites (`ADDI`/`ADD`/`SUBI`/`SUB`/`MUL`/`DIV`/`ADDILV`/`SUBILV`),
  `compile_cmp`'s own pair check for `EQ`/`LT`/`LE`/`GT`/`GE`, and the
  three `static_indexable_class` call sites (`GETIDX`, `GETIDX0`,
  `SETIDX`). The subtraction is total, not defensive: the delegation's own
  `gsub(/R(\d+)/)` shifts EVERY register reference in the instruction, so a
  real operand always satisfies `reg >= reg_offset`. The nine emitters
  that walk a block body (`emit_times_inline`, `emit_each_inline`,
  `emit_each_index_inline`, `emit_hash_each_inline`,
  `emit_each_key_inline`, `emit_range_each_inline`, and
  `emit_collect_inline`/`emit_accum_inline`/`emit_sort_inline` through
  `compile_collect_body_insn`) already iterate
  `block_irep.instructions` in order, skipping only `ENTER` and never
  reordering, so five of them simply stop discarding the index
  `each_with_index` was already producing for `with_element_hint`, and
  four switch from `each` to `each_with_index`.

  **Nothing else needed re-scoping, which is the point.** Everything the
  dominance logic consults was already correct for a block body:
  `jump_targets(block_irep)`, `block_irep.catch_handlers`,
  `subtree_upvar_written_regs(block_irep)` and the instruction addresses
  themselves (`insn.addr` is carried through unchanged into the relabeled
  copy -- there is no `glue_at`/suppressed-address remapping inside an
  inlined body at all, unlike `emit_proc_fallback_fn`'s nested regions).
  `owner_def` deliberately stays the ENCLOSING method's, which is exactly
  right for the ivar facts (a block's `self` IS its enclosing method's
  `self`) while `fixnum_proof_entry_arg?`'s own `owner_def.irep ==
  irep.label` guard keeps that method's `NATIVE_ARG_TARGETS` `mrb_int`
  parameter types from being misread as the block's own parameters -- the
  identical guard `BLOCK_FALLBACK` bodies already relied on. The
  `SETUPVAR`-written-register refusal is likewise unchanged and still
  live: `subtree_upvar_written_regs` walks the whole child-irep subtree at
  any depth, so a nested block writing one of this body's registers is
  refused the same way at any nesting level (86 real operand slots hit
  that refusal across the build). Inside an inlined body specifically it is
  belt-and-braces today, because `compile_insn` has no `BLOCK`/`SENDB`
  case at all: a nested block there still produces `#error unhandled
  opcode BLOCK`, which discards the whole inlined region before any of
  this can matter.

  **What moved, measured on the real `SKIP_UNSUPPORTED=1` whole-program
  output** (`scripts/bc2cpp_coverage_report.rb` scans exactly that text):
  statically-proven-`Hash` indexed accesses 691 -> 703 and
  statically-proven-`Array` ones 117 -> 121. The 12 new `Hash` proofs each
  delete a real `mrb_funcall` (the `Hash` arm is a bare `mrb_hash_get`/
  `mrb_hash_set` with no fallback branch), which is precisely the 10 `:[]`
  plus 2 `:[]=` the dispatch counts lost; the 4 new `Array` proofs keep
  their non-integer-index `mrb_funcall` by design, so they buy a smaller
  emitted body (one `mrb_array_p` assertion instead of a four-way
  Array/Hash/String/else type test) rather than a dispatch-count win. Real
  example in the shipped output: `Game::Battle#apply_stat_mods`'s
  `keys.each do |key| ... STAT_MOD_FIELD[key] ... end`, where the frozen
  `Game::Battle::STAT_MOD_FIELD` Hash literal constant is now read with a
  direct `mrb_hash_get`; and `Game::State#seed_screen_transitions`'s
  `DB_TRANSITION_FIELDS.each_with_index do |field, i|` body, whose
  `@screen_transitions[i]` read and `@screen_transitions[i] = ...` write
  are both proven `Array` from the same `@class_layout` ivar fact the
  enclosing method already uses.

  **`FIXNUM_OPERAND_PROOF` gained nothing yet, and that is a measurement,
  not a guess.** An instrumented run over the whole build shows the index
  threading makes 766 real arithmetic/comparison operand slots inside
  inlined block bodies reachable for the first time (the
  `bc2cpp-proven-fixnum-arith-devirt` fragment's own estimate of this
  bucket was ~839), and 24 of them do now prove -- but no `ADD`/`SUB`/
  `MUL`/`DIV`/`EQ`/`LT`/`LE`/`GT`/`GE` site gets BOTH operands proven and
  no `ADDI`/`SUBI`/`ADDILV`/`SUBILV` destination proves, so the count of
  `// operands proven Fixnum` markers in the generated C++ is unchanged at
  70. Where the other 742 go, by refusal reason: 181 fall off the top of
  the block body (the loop parameter registers -- the element, the index,
  the accumulator -- are bound by the EMITTER, outside the translated
  instruction stream, so nothing in the body ever writes them and the
  scan correctly refuses), 115 to the dominance rule (a real `goto` label
  between the write and the use), 104 to a `GETUPVAR` of an enclosing
  local, 96 to a `GETCONST`, 88+44+32 to a `SEND0`/`SSEND`/`SEND` result
  whose type nothing here infers, 46+2 to a `GETIDX`/`GETIDX0` element
  read, 13 to a `DIV` result (deliberately not a proof source), 9 to a
  `GETIV` of a non-embeddable ivar, 6 to a `GETMCNST`, 4 to an `AREF`, and
  2 to a `SETUPVAR` the whitelist refuses to step over. The single
  largest bucket -- the loop parameter itself -- would need a new proof
  source ("the register this emitter binds to `mrb_fixnum_value(bc2cpp_
  times_i_N)` is a Fixnum by construction"), which is a separate mechanism
  with its own soundness argument and is deliberately not invented here.

  One delegation deliberately keeps the old `idx: nil` bail: `compile_
  send`. Unlike the proofs above, which ask about the one or two register
  numbers `compile_insn` has already extracted and only ever read them,
  `compile_send` re-parses `args` itself, derives a whole `r<d>..r<d+n>`
  receiver/argument window, and feeds those raw numbers to six backward
  scans -- two of which (`compile_keyword_send`, `compile_splat_send`)
  hand REGISTER LISTS back out to be printed straight into the generated
  C++, so they would need the shift re-applied on the way out as well as
  removed on the way in. Threading the offset through only the four
  read-only scans (`trace_eqq_literal_receiver`, the two `.new`
  `trace_new_target` calls and the TYPED `trace_new_target`) was
  implemented and measured against the same build: it moved 18 call sites
  between the POLY-marked and not-yet-attempted buckets and removed
  exactly zero of them, so it is not carried here.

  Verified with `ruby -c`, a regenerated `docs/bc2cpp_coverage.txt` whose
  ONLY moving lines are the dispatch total, the not-yet-attempted half of
  its split (the POLY-marked half is unchanged at 7140) and the two
  operator counts above (compiled entry points, per-method coverage,
  `BLOCK_FALLBACK`/`LAMBDA_FALLBACK` counts and the `#error` total are
  byte-identical), `scripts/rpg2k_logic_check.rb` (1201 checks),
  `scripts/rpg2k_scene_check.rb` (1062 checks) and
  `scripts/lcf_testbed_check.rb` all unchanged, and a real `g++ -std=c++17
  -fsyntax-only` pass over the whole generated translation unit reporting
  exactly the same 17 pre-existing, unrelated errors (12 `could not
  convert '1' from 'int' to 'mrb_value'`, 5 `RPG2k::Scene::Map#vehicle_
  blocks` arity) and zero new ones. The checked-in
  `docs/bc2cpp_coverage.txt` was stale relative to the last merge, so the
  diff here also folds in that pre-existing drift; the 14628 -> 14616
  figure is measured against a freshly regenerated baseline, not against
  the stale file.
