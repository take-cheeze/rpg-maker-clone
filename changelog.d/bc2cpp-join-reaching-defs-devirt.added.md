- `tools/bc2cpp/bc2cpp.rb`'s `FIXNUM_OPERAND_PROOF` gains
  `JOIN_REACHING_DEFS`, the real reaching-definitions walk that
  `REGION_DOMINANCE`'s own changelog entry named as its single biggest
  piece of deliberately-unclaimed ground ("proving that needs all
  REACHING definitions checked, not just the nearest one, a different
  mechanism with its own soundness argument"). The real shipped
  whole-program build (`SKIP_UNSUPPORTED=1`) goes from 14904 to 14868
  `mrb_funcall`/`mrb_funcall_with_block` call sites -- 36 removed -- and
  the `// operands proven Fixnum` marker count in the generated C++ goes
  556 -> 592, the same 36. Every arithmetic and comparison name drops:
  `:+` 725 -> 718, `:-` 506 -> 497, `:*` 485 -> 479, `:/` 297 -> 290,
  `:>` 285 -> 281, `:==` 639 -> 637, `:<` 253 -> 252.

  THE SHAPE, from a real `mrbc -v` disassembly (this repo's own
  3rd/mruby host mrbc, mruby 4.0.0) of
  `if cond; x = 5; else; x = 7; end; y = x + 1`:

      004 MOVE    R5 R1       ; R1:cond
      007 JMPNOT  R5 016
      011 LOADI_5 R3 (5)      ; R3:x      -- then-arm write
      013 JMP     018
      016 LOADI_7 R3 (7)      ; R3:x      -- else-arm write
      018 MOVE    R5 R3       ; R3:x      -- join label, and the use
      021 ADDI    R5 1

  `REGION_DOMINANCE` refuses this, and refuses it CORRECTLY under its own
  rule: the backward walk renames through the `MOVE` at 018, finds
  `LOADI_7` at 016 as the nearest write, making the region `[016, 021]`,
  and the join label 018 sits inside it with one in-edge -- the `JMP` at
  013, BELOW `lo`. That is a real path reaching the use without executing
  016, so 016 genuinely does not dominate. What a single-write rule
  cannot express is that the path skipping 016 ran `LOADI_5` at 011
  instead, which is just as good a proof.

  MEASURED BEFORE BEING WRITTEN, by the same refusal-instrumentation
  methodology `FIXNUM_RETURN_PROOF` used: tagging every refusal inside
  `proven_fixnum_operand?` with its exact cause across a whole-program
  run and counting only the COSTLY ones (a refusal only costs a real call
  site when the OTHER operand of the pair already proves) put this join
  geometry at 770 costly refusals -- the largest STRUCTURAL cause by a
  wide margin, behind only "the write was a SEND result" (1304) and ahead
  of `GETIV` (524), `GETIDX` (428) and `DIV` (396). The instrumentation
  also separated out the genuinely different back-edge geometry (a branch
  source ABOVE the region, i.e. a loop rewriting the register after the
  use) at a much smaller 62; that one is not a dominance-rule problem and
  is handled here only incidentally, because the CFG walk follows
  back-edges as real edges like any other.

  THE MECHANISM is reaching-definitions dataflow rather than a cleverer
  dominance predicate, because the property actually needed is a
  reaching-definitions property: a use is provably Fixnum iff EVERY
  definition reaching it along ANY real path is itself a proof source.
  Dominance is merely the special case where that set has one element.
  The walk is backward over the real CFG with state `(k, reg)` -- "every
  definition of `reg` reaching the point just before instruction `k`" --
  enumerating that point's predecessors as the fall-through `k - 1` plus,
  when `addr(k)` is a control-flow entry, every instruction branching to
  it. It reuses `fixnum_proof_edge_sources`, the edge map `REGION_
  DOMINANCE` already built and already verified complete against
  3rd/mruby's own `include/mruby/ops.h` (exactly `JMP`/`JMPUW`/`JMPIF`/
  `JMPNOT`/`JMPNIL` move `pc` within a frame); no second CFG is invented
  and nothing new is trusted about control flow. A predecessor that
  writes the register terminates that path -- it executes on every path
  through it, so it kills everything earlier, which is exactly why a
  branch target that is itself a write needs no predecessor enumeration
  -- and must then satisfy the existing `fixnum_proof_source?`
  recursively, same bounded depth, same six sources, with `MOVE`
  renaming the traced register per path. Falling off the top is method
  entry and defers to the unchanged `fixnum_proof_entry_arg?`.

  NO PARTIAL CREDIT, and the refusal set is the linear scan's own,
  re-checked at every step: any single unprovable reaching definition,
  any unmodelled edge, any catch-handler target (reached by a raise,
  which has no source instruction to enumerate), any address inside a
  protected range, any opcode outside `FIXNUM_PROOF_STEP_OVER_OPS`, any
  `SETUPVAR`-written register, or more than `FIXNUM_JOIN_MAX_STATES`
  (96) states refuses the whole query. It is wired in ONLY as a fallback
  at the two points where `fixnum_proof_region_ok?` refuses, so it can
  never turn a currently-proven operand into an unproven one -- it only
  ever examines queries that are already refusals today.

  Loops need no special case: a use inside a loop body reaches its head
  label, whose in-edges include the real back-edge, so the walk continues
  backward THROUGH the loop body and finds a conditional rewrite there if
  one exists -- the "second and later iteration" reaching definition a
  textual backward scan would miss. The `seen` set on `(k, reg)` pairs is
  what terminates it. Verified by a matched pair that differs in exactly
  one token: `x = 5; i = 0; while i < 10; y = x + 1; x = 9 if flag;
  i = i + 1; end` proves, while the identical body with `x = "boom" if
  flag` refuses -- so the walk demonstrably follows the back-edge and
  inspects the in-loop definition rather than refusing for an unrelated
  reason.

  Soundness spot-checks against real generated output, all confirmed in
  the actual emitted C++: both-arms-LOADI proves; a four-arm nested
  `if`/`else` proves; one arm `LOADI` with the other a proven arithmetic
  result proves (different proof sources per arm); `if cond; x = 5; end;
  x + 1` with NO else arm REFUSES (x can be nil, and the walk reaches
  method entry for a non-argument register); a three-way `if`/`elsif`
  with a fall-through arm REFUSES for the same reason; an arm assigning a
  String REFUSES; and `if cond; x = n + 1; else; x = 7; end` REFUSES
  while `n` is an unproven argument -- no partial credit for the arm that
  does prove.

  A real second-order effect, not a separate change: methods proven
  Fixnum-returning (`FIXNUM_RETURN_PROOF`) goes 28 -> 48. That pass
  proves a method's every `RETURN` site holds a Fixnum using this same
  `proven_fixnum_operand?`, so 20 more methods qualify once join-shaped
  return sites resolve -- and each one is itself proof source 6 for its
  own call sites.

  VERIFICATION. `docs/bc2cpp_coverage.txt` regenerated with the mruby
  submodules initialized (an uninitialized `3rd/mruby` empties
  `NATIVE_SRCS` and silently changes the result) and confirmed to
  reproduce the committed baseline byte for byte before any change.
  Compiled entry points stay 2287, method-level coverage stays 98.6%,
  total `#error` markers stay 48, and every `#error`-by-reason line is
  unchanged -- this round moves dispatch only, never coverage.
  `scripts/rpg2k_logic_check.rb` (1201), `scripts/rpg2k_scene_check.rb`
  (1062) and `scripts/lcf_testbed_check.rb` all pass with identical
  counts. A real `g++ -std=c++17 -fsyntax-only` compile of the actual
  `SKIP_UNSUPPORTED=1` whole-program output reports ZERO errors,
  unchanged from baseline.

  KNOWN, DELIBERATELY-UNCLAIMED GROUND, measured rather than guessed.
  Instrumenting the new walk's own outcomes across a whole-program run:
  143 queries accepted, against 281 blocked by `JMPIF`, 188 by `ADD`,
  138 by `ADDILV`, 131 by `LOADNIL`, ~200 by the SEND family, 51 by
  method entry. The `JMPIF` figure is the notable one and is NOT a join
  problem at all -- it is a pre-existing conservatism in the shared
  `/\AR<reg>\b/` definition test, which treats `JMPIF R5 <target>` as a
  DEFINITION of R5 even though ops.h's `BS` format makes that register
  purely a read. Every such hit is a false definition that refuses a
  provable operand, on this path and on the linear one. Fixing it is
  sound and mechanical but changes the definition test every existing
  proof shares, so it wants its own measured round rather than a
  drive-by here. `LOADNIL` blocks are correct refusals (a genuinely
  nil-able arm), and the SEND-family blocks belong to
  `FIXNUM_RETURN_PROOF`'s own direction.
