- `tools/bc2cpp/bc2cpp.rb` closes the if/else-join dominance gap that the last
  three rounds each named and none attempted. `proven_fixnum_operand?`'s
  `REGION_DOMINANCE` test asks about exactly ONE reaching write and demands it
  dominate the use, so it necessarily refuses a JOIN -- `x = cond ? 5 : 7`, or
  an `if` assigning `x` in both arms -- where no single write dominates even
  though every write reaching the use is a literal. A failed dominance test no
  longer ends the proof: it now hands over to `fixnum_proof_reaching_defs?`, a
  real multi-path reaching-definitions walk that demands EVERY definition
  reaching the use prove independently. On the real shipped whole-program build
  (`SKIP_UNSUPPORTED=1`, the same output `scripts/bc2cpp_coverage_report.rb`
  scans, submodules initialized) this takes `mrb_funcall`/
  `mrb_funcall_with_block` call sites from 14904 to 14860 -- 44 removed. The
  `// operands proven Fixnum` marker count goes 556 -> 600. Per operator: `+`
  725 -> 713, `-` 506 -> 497, `*` 485 -> 479, `/` 297 -> 290, `==` 639 -> 636,
  `>` 285 -> 281, `<` 253 -> 251, `<=` 127 -> 126, summing to exactly 44 with
  nothing else moving.

  Direction chosen by re-running the previous rounds' instrumentation
  methodology fresh rather than trusting their ranking, which had shifted. A
  one-off build tagging every refusal inside `proven_fixnum_operand?` across all
  7239 whole-program `proven_fixnum_pair?` queries (6279 failing), counting only
  COSTLY refusals (a refusal costs a real call site only when the OTHER operand
  already proves), now ranks: SEND-family 1026 (`SEND0` 537, `SEND` 304, `SSEND`
  120, `SSEND0` 65), `ea_NOT_IN_NATIVE_ARG_TARGETS` 344, `GETIV` 231, `MUL` 230,
  `ea_NOT_TOPLEVEL_IREP` 213, `GETIDX` 186, `DIV` 162, `region_LOADI_0` 151.
  Ceiling runs with one refusal forcibly disabled (deliberately unsound,
  measurement only) put the region/dominance direction at -320, ahead of
  `GETIDX` -246 and `DIV` -126, and behind only the entry-argument direction at
  -466.

  THE SHAPE, verified against real `mrbc -v` disassembly rather than assumed.
  `p = span <= 0 ? 1 : @frame` compiles to

      011 JMPNOT  R3  020
      015 LOADI_1 R3  (1)
      017 JMP     023
      020 GETIV   R3  @frame
      023 MOVE    R2  R3      <- the join

  The backward walk finds `GETIV R3 @frame` at 020 as the nearest write, makes
  the region [020, 023], and refuses: label 023 has an in-edge from 017, which
  is below the region. Both reaching definitions are nonetheless provable --
  `LOADI_1` outright, `GETIV @frame` by the existing embedded-`:fixnum` ivar
  source -- which is exactly what the new walk establishes.

  THE WALK. A plain backward worklist over (instruction index, register) states,
  where (i, r) means "the value of `r` flowing INTO instruction i must be
  Fixnum". For each predecessor p of i: if p writes r it is a reaching
  definition -- a `MOVE` continues the walk at (p, source register), anything
  else must satisfy the same `fixnum_proof_source?` the single-path walk already
  uses; if p does not write r the question moves back to (p, r). The
  method-entry sentinel falls back to the same `fixnum_proof_entry_arg?` test.

  `need_idx` is load-bearing and is the one place the multi-path walk genuinely
  differs from the single-path one. A `MOVE Ra Rb` reads `Rb` at ITS OWN
  address, not at the original use, so "what reaches this register" has to be
  asked at the `MOVE`. The single-path walk never needed the distinction (it
  only ever inspects instructions it has already scanned past); starting the
  multi-path walk at the use instead would ask about a register later code is
  free to overwrite, which would be a wrong answer rather than a missed proof.

  SOUNDNESS. Termination and correctness both come from `seen`: every state is
  expanded at most once, and the walk returns true only after the worklist is
  EMPTY -- i.e. after every state reachable backward from the use has been
  expanded and every terminal definition among them checked. Re-reaching an
  already-seen state, which is exactly what a loop back-edge does, is therefore
  memoization and not an optimistic assumption: that state's own definitions are
  checked by the expansion that first queued it. This is a least fixpoint over
  states, so unlike `FIXNUM_RETURN_PROOF`'s greatest fixpoint it needs no
  separate induction on the dynamic call tree.

  The predecessor map (`fixnum_proof_preds`) is built so that its error
  direction is always the safe one: an EXTRA predecessor costs only a missed
  proof, a MISSING one is a wrong answer. Fall-through is therefore assumed for
  every opcode except the ten verified against `3rd/mruby/include/mruby/ops.h`
  and `src/vm.c` to never fall through at all (`JMP`/`JMPUW`, and
  `RETURN`/`RETURN_BLK`/`RETSELF`/`RETNIL`/`RETTRUE`/`RETFALSE`/`BREAK`/`STOP`,
  which all leave the frame), and the branch edges are exactly the five `JMP*`
  opcodes `fixnum_proof_edge_sources` already enumerates against that same
  header. A jump whose target address has no instruction returns nil for the
  WHOLE map, making every query refuse -- an unmodelled edge must never silently
  look like "no edge".

  Every barrier the single-path walk honours is honoured identically: an address
  inside a catch handler's protected range refuses (`RESCUE_SUPPORT` extracts
  that range into a separate function with re-initialized registers), a
  catch-handler target refuses (reached by a raise, which has no source
  instruction any predecessor map can contain), an opcode outside
  `FIXNUM_PROOF_STEP_OVER_OPS` refuses (it may write the register from an
  operand position this scan does not read), and a register any `SETUPVAR` in
  the child-irep subtree writes refuses. `FIXNUM_PROOF_REACHING_MAX_STATES` caps
  expansion at 400 states; a re-measurement at 5000 removes exactly the same 44
  sites, so the bound is not binding on this program and exists only to keep a
  pathological irep from making a linear codegen pass superlinear.

  WHERE IT FIRES: 23 methods, deltas summing to exactly 44. The largest are
  `RPG2k::Window#draw_cursor_skin` (+6), `RPG2k::Scene::DebugMenu#build_editor_window`
  (+6), `Game::Transition#border_to_center_rect` (+4),
  `Game::Transition#center_to_border_rect` (+4), `Game::Battle#apply_skill_hit`
  (+4). `center_to_border_rect` is the mechanism in one method: it opens
  `p = span <= 0 ? 1 : @frame` and `d = span <= 0 ? 1 : span` -- two ternary
  joins -- and the four sites it gains are precisely the `* p` and `/ d`
  operations in `[@width / 2 - (@width / 2) * p / d, ...]`, each of which was
  refused only because `p` and `d` came from a join.

  A real knock-on, not a regression: `FIXNUM_RETURN_PROOF` rises 28 -> 49.
  That mechanism admits a method when every one of its real `RETURN` paths is
  proven, and it reaches those paths through this same
  `proven_fixnum_operand?`, so 21 further methods now have all return paths
  proven. The `cond ? CONST_A : CONST_B` methods the previous round explicitly
  diagnosed as blocked by this exact gap (`recover_cap`, `damage_cap`,
  `editor_digits`) are among them.

  TWO DIRECTIONS INVESTIGATED AND DECLINED, measured rather than asserted, both
  of which the previous round had ranked ahead of this one.

  `DIV` as a proof source is worth zero and should not be retried. The semantic
  question does have a clean answer: `mrb_div_int_value` (3rd/mruby/src/numeric.c)
  raises on `y == 0`, raises or returns a Bignum on `x == MRB_INT_MIN && y == -1`,
  and otherwise returns `mrb_int_value(mrb, mrb_div_int(x, y))` -- and
  `mrb_int_value` is NOT unconditionally a Fixnum: under word boxing
  `SET_INT_VALUE` is `mrb_boxing_int_value`, which (src/etc.c) returns a heap
  `RInteger` whenever `!FIXABLE(n)`. Worth recording, because mruby's own
  overflow guard tests `MRB_INT_MIN` while the dangerous case for a
  `mrb_fixnum_p`-gated fast path is `x == FIXNUM_MIN && y == -1`, and under word
  boxing those are different values -- so a divisor proven neither 0 nor -1 is
  genuinely required, not merely prudent. But the yield is the problem, not the
  soundness: a sound rule must also prove the DIVIDEND, and measurement says the
  dividend is what is missing. Admitting `DIV` with a proven-literal divisor not
  in {0, -1} removes 0 sites; admitting it whenever both its own operands prove,
  with no literal restriction at all, removes 10; the -126 ceiling is almost
  entirely `DIV`s whose dividend is itself a `SEND` or `GETIDX` result. The
  header's long-standing refusal of `DIV` costs this program essentially
  nothing.

  `GETIDX`/element typing has a soundness hole that the ELEM_HINT machinery
  cannot close. `arr[i]` returns nil for an out-of-range index no matter what
  every element's class is, and `hash[k]` returns nil (or a default) for a
  missing key, so "all elements are Integer" does not prove `arr[i]` is a
  Fixnum; the existing `ArrayElementLayout`/`HashElementLayout` hints prove the
  element fact and not the in-range fact, and nothing in this file proves the
  latter. The -246 ceiling is therefore not reachable soundly by element typing
  alone. The real idiom this program uses -- `@parameters[i] || 0`, named by the
  previous round as the single biggest SEND-family blocker -- is for the same
  reason a JOIN, and it is correctly still refused here: its truthy arm is the
  raw `GETIDX`, which is not a Fixnum merely by being truthy. Cracking that one
  needs edge-sensitive reasoning (knowing the `JMPIF`-taken edge excludes nil)
  layered on element typing, which is a different mechanism with its own
  soundness argument and is deliberately left for a future round.

  Verification: `ruby -c` clean; `scripts/rpg2k_logic_check.rb` (1201),
  `scripts/rpg2k_scene_check.rb` (1062) and `scripts/lcf_testbed_check.rb` all
  pass with identical counts. A real `g++ -std=c++17 -fsyntax-only` pass over
  the whole generated `SKIP_UNSUPPORTED=1` translation unit reports ZERO errors,
  the same as the baseline -- the stricter bar that applies now that the
  previously-documented 17 pre-existing errors are fixed. The generated-output
  diff against baseline contains nothing but the devirtualizations: 44 added
  `// operands proven Fixnum` markers against 38 removed binary-operator
  `if (mrb_fixnum_p(..) && mrb_fixnum_p(..)) { .. } else { mrb_funcall(..) }`
  blocks and 6 removed single-operand `ADDI`/`SUBI` `mrb_integer_p` blocks,
  38 + 6 = 44, with no other codegen change anywhere. In
  `docs/bc2cpp_coverage.txt` the only lines that move are the
  FIXNUM_RETURN_PROOF count (28 -> 49), the call-site total (14904 -> 14860),
  its non-POLY half (8659 -> 8615) and the eight per-operator entries above;
  compiled entry points (2287), method-level coverage (98.6%), the `#error`
  total (48), POLY-marked sites (6245), distinct dispatched names (1033) and the
  BLOCK_FALLBACK/LAMBDA_FALLBACK counts are all byte-identical. The committed
  baseline was first confirmed to regenerate byte for byte with `3rd/mruby` and
  its sibling gems checked out, since an uninitialized submodule empties
  `NATIVE_SRCS` and silently breaks the registry-dependent proofs this
  measurement rests on.
