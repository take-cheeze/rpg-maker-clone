- `tools/bc2cpp/bc2cpp.rb` gains `FIXNUM_OPERAND_PROOF`: a static "this
  register is provably a Fixnum at this exact program point" proof
  (`proven_fixnum_operand?`/`proven_fixnum_pair?`, sitting right next to
  `static_indexable_class`, whose static-receiver-class proof for
  `[]`/`[]=` it deliberately mirrors) that lets `ADD`/`ADDI`/`ADDILV`/
  `SUB`/`SUBI`/`SUBILV`/`MUL`/`DIV` and `compile_cmp`'s own
  `EQ`/`LT`/`LE`/`GT`/`GE` emit ONLY their native computation -- no
  `mrb_fixnum_p` runtime check, no `else` branch, and crucially no
  `mrb_funcall` fallback call site at all.

  Why those call sites existed in the first place: every one of those
  nine opcodes already had a Fixnum-Fixnum fast path, but it was always
  paired with an unconditional `mrb_funcall(M, r<d>, "<op>", 1, r<s>)`
  else-branch for the non-Fixnum case. `scripts/bc2cpp_coverage_report.
  rb` counts dynamic dispatch by scanning the real generated C++ for
  `mrb_funcall(...)` text, so that else-branch was a permanent
  dispatch-count hit at EVERY arithmetic and comparison instruction in
  the whole program -- including the many where both operands are
  structurally incapable of being anything but a Fixnum and the branch
  can never execute. It was also real code g++ had to compile and the
  linker had to keep.

  Exactly four proof sources, each one a fact this file already computes
  and already trusts elsewhere -- never a general dataflow/SSA prover
  (`fixnum_proof_source?`):

  1. An integer literal load: any `LOADI`-family opcode (`LOADI8`/
     `LOADI16`/`LOADI32`/`LOADINEG`/`LOADI__1`/`LOADI_0`..`LOADI_7`, the
     full set 3rd/mruby's own `include/mruby/ops.h` declares, matched by
     the same `/\ALOADI/` `compile_insn` already uses for their shared
     codegen) emits `mrb_fixnum_value(<literal>)` and nothing else.
  2. A `NATIVE_ARG_TARGETS`-typed `:fixnum` mandatory argument register
     that has not been reassigned since method entry
     (`fixnum_proof_entry_arg?`). `compile_method`'s own preamble emits
     `r<i+1> = mrb_fixnum_value(<arg>)` for exactly these, and the C++
     parameter is a real `mrb_int` -- the boxed register value is a
     Fixnum by C++ type, not by hope. Gated on `owner_def.irep ==
     irep.label` (a BLOCK_FALLBACK child irep reaches `compile_insn`
     with the ENCLOSING method's `owner_def`, whose annotation describes
     nothing about the block's own parameters) and on
     `pure_mandatory_arity?` (with real optional arguments the register
     numbering no longer maps 1:1 onto `native_arg_types`' slots).
  3. A `GETIV` of an ivar `IvarLayout` proved embeddable as `:fixnum`:
     `compile_insn`'s own GETIV case emits
     `r<d> = mrb_fixnum_value(((Owner_ivars*)DATA_PTR(self))->@ivar)` for
     exactly these, and every write site to that struct field already
     carries a raising `mrb_integer_p` guard (the embedded-ivar SETIV
     codegen), so the field can never hold anything else.
  4. An `ADD`/`SUB`/`MUL`/`ADDI`/`SUBI` whose OWN operands are proven by
     1-4 (bounded recursion, `FIXNUM_PROOF_MAX_DEPTH = 4`). Not circular:
     an op whose operands are proven is emitted by this same mechanism as
     the bare `mrb_fixnum_value(a <op> b)` form, so its destination
     demonstrably holds a Fixnum. `DIV` is deliberately NOT a source --
     devirtualizing a DIV is safe (its own two operands are what gets
     proven), but trusting `mrb_div_int_value`'s RESULT type across every
     overflow/bigint configuration is a separate question this round
     declined rather than guessed at.

  `MOVE` chains are followed the way `trace_new_target`/
  `proven_array_source_scan`/`trace_eqq_literal_receiver` already follow
  them (`OP_MOVE` is a verbatim `regs[a] = regs[b]` copy), so a value
  mrbc shuffled through a temporary is still provable -- this is what
  makes `Game::Map#in_bounds?`'s `x >= 0`/`y >= 0` provable, since mrbc
  emits `MOVE R4 R1` before the compare rather than comparing the
  argument register directly.

  The genuinely new part, and what everything above rests on, is
  DOMINANCE: a backward scan for "the most recent write" only means
  anything if control cannot ENTER the instruction stream between that
  write and this use. Three real entry-point kinds exist in a compiled
  body and all three are honoured (`fixnum_proof_ctx`):

  - A `goto` target. `jump_targets(irep)` is the exact set
    `compile_method` itself emits a real C `L<addr>:` label for; the walk
    refuses to step back past any of them, and refuses outright when the
    USE's own address is one.
  - An exception handler. Each `Irep#catch_handlers` entry contributes
    its `target` to the entry set (that address is reached by a raise,
    never by a `goto` `jump_targets` could see) AND its whole
    `begin_addr..end_addr` protected range to a second, stronger barrier
    that refuses the proof at the use and at every step of the walk.
    Both halves are load-bearing: `RESCUE_SUPPORT` extracts exactly that
    range into a separate C++ function (`emit_rescue_try_body`) whose
    registers are re-initialized from a Ctx struct carrying only `self`
    and the method's arguments, and that function calls this same
    `compile_insn` with the ENCLOSING irep and real instruction indices,
    so without the range barrier the walk would step from inside the
    extracted function back out into code no longer in front of it.
  - A nested block writing an enclosing local. `SETUPVAR R<src> <b> <lv>`
    compiles to a direct `r<b> = ...` (inlined block bodies,
    `compile_block_body_insn`) or `*bc2cpp_upvar_<b> = ...` against
    `&r<b>` (BLOCK_FALLBACK bodies, `UPVAR_CAPTURE_SUPPORT`) -- a real
    write to an enclosing register that this irep's own instruction list
    does not contain. `subtree_upvar_written_regs` collects every
    `SETUPVAR` destination anywhere in the whole child-irep subtree (any
    depth, deliberately ignoring the level operand) once per irep and
    refuses those registers as operands; it fires on 51 real operand
    slots in this program, so this is a live hazard, not a hypothetical
    one.

  `FIXNUM_PROOF_STEP_OVER_OPS` is a whitelist, not a blacklist: only
  opcodes verified (against `ops.h` plus each one's own codegen in this
  file) to write at most the single register named by their first `R<n>`
  operand may be stepped over. `RESCUE` (writes its SECOND operand,
  `R[b] = R[a].isa?(R[b])`), `APOST` (writes a whole `a..a+b+c` range),
  `ARGARY` (writes `a` AND `a+1`), `ASET`, `SETUPVAR`, `EXCEPT`/
  `RAISEIF`/`MATCHERR`/`JMPUW`, `CALL`, `ERR` and `EXT1`/`EXT2`/`EXT3`
  are all absent and end the walk with a refusal, as does any future
  opcode this list has not been re-audited for. Over-approximating a
  WRITE only ever costs a missed proof; under-approximating one would be
  a wrong answer, which is why the list runs this direction. An inlined
  block body (`compile_block_body_insn`'s `compile_insn(shifted,
  block_irep, owner_def, nil)`) passes no instruction index at all and so
  declines unconditionally -- its shifted register numbers do not
  correspond 1:1 with positions in `block_irep.instructions`, the same
  `idx.nil?` bail `static_indexable_class` already takes.

  Every decline is silent and falls straight through to today's unchanged
  dual-path codegen, which is always correct -- just not a size win. A
  proven site gets a `// operands proven Fixnum -- no runtime check, no
  mrb_funcall fallback` marker in the generated C++, mirroring the
  embedded-ivar `// @x embedded (fixnum)` note, so a real generated body
  says why it has no fallback.

  Measured on the real shipped whole-program build (`SKIP_UNSUPPORTED=1`,
  the same output `scripts/bc2cpp_coverage_report.rb` scans): 70 real
  call sites flip, total `mrb_funcall`/`mrb_funcall_with_block` call
  sites 14678 -> 14608. Per operator: `+` 718 -> 700, `-` 633 -> 625,
  `*` 603 -> 602, `/` 341 -> 332, `==` 632 -> 627, `<` 242 -> 238,
  `<=` 133 -> 128, `>` 292 -> 280, `>=` 149 -> 141. Nothing else in
  `docs/bc2cpp_coverage.txt` moves at all -- compiled entry points,
  per-method coverage, BLOCK_FALLBACK/LAMBDA_FALLBACK counts and the
  `#error` total are byte-identical, and the real g++ `-fsyntax-only`
  pass over the whole generated translation unit still reports exactly
  the same 17 pre-existing, unrelated errors (12 `could not convert '1'
  from 'int' to 'mrb_value'`, 5 `RPG2k::Scene::Map#vehicle_blocks` arity)
  and zero new ones. `scripts/rpg2k_logic_check.rb` (1201),
  `scripts/rpg2k_scene_check.rb` (1062) and
  `scripts/lcf_testbed_check.rb` all still pass with identical counts.

  Real examples in the shipped output: `Game::Transition#done?`
  (`@frame >= @frames`, two embedded-`:fixnum` ivars -- the whole body is
  now three unconditional lines), `Game::Map#in_bounds?` (its two
  `>= 0` guards, from the `mrb_int x`/`mrb_int y` parameters
  `NATIVE_ARG_TARGETS` already gives it -- while its `< @width`/
  `< @height` halves correctly keep the dual path, since those two ivars
  are not embedded), `Game::Switches#[]=`'s `@revision + 1`, and
  `Game::Actor#strong_defence?`'s `@class_changed && @class_id > 0`
  guard -- whose very next line, a `respond_to?` on a genuinely
  polymorphic receiver, still dispatches dynamically, which is exactly
  the intended split.

  Known, deliberately-unclaimed ground, measured rather than guessed
  (from a one-off instrumented run over all 8707 real operand slots the
  proof was asked about): 1361 slots are lost purely to the dominance
  rule (a `goto` label between the write and the use), 1489 to a method
  call result (`SEND0`/`SEND`/`SSEND`/`SSEND0`) whose return type nothing
  here infers, 839 to inlined block bodies having no instruction index,
  522 to a `GETIV` of an ivar that is not embeddable, and 358 to a
  `GETIDX` element read. Each of those is a separate mechanism with its
  own soundness argument, not a tuning knob on this one.
