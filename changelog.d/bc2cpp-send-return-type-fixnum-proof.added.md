- `tools/bc2cpp/bc2cpp.rb` grows `FIXNUM_RETURN_PROOF`, a sixth
  `proven_fixnum_operand?` proof source: a `SEND`/`SEND0`/`SSEND`/`SSEND0`
  whose CALLEE provably returns a Fixnum on every return path now counts as
  a proof, exactly like the existing `LOADI`/ivar/constant sources. On the
  real shipped whole-program build (`SKIP_UNSUPPORTED=1`, the same output
  `scripts/bc2cpp_coverage_report.rb` scans, submodules initialized) this
  takes `mrb_funcall`/`mrb_funcall_with_block` call sites from 14933 to
  14895 -- 38 removed -- and proves 28 method names. The
  `// operands proven Fixnum` marker count goes 514 -> 552. Per operator:
  `==` 666 -> 639, `<=` 134 -> 127, `-` 506 -> 504, `>` 287 -> 285, summing
  to exactly 38 with nothing else moving.

  The measured ceiling for this direction is 783 sites, and this change
  captures 38 of it. That ratio is the headline finding of the round, not a
  footnote -- see "what the ceiling is actually made of" below.

  Direction and scope both chosen by re-running the previous rounds' own
  instrumentation methodology fresh rather than trusting their numbers: a
  one-off build tagging every refusal inside `proven_fixnum_operand?` across
  all 7215 whole-program `proven_fixnum_pair?` queries (6303 failing), then
  ceiling runs with one refusal reason forcibly disabled. Counting only
  COSTLY refusals (a refusal costs a real call site only when the OTHER
  operand already proves), a SEND-family result leads at 1249, ahead of
  `GETIDX` 214, `DIV` 198, `GETUPVAR` 76 and `AREF` 68; treating EVERY
  SEND-family result as a Fixnum removes 783 sites (14933 -> 14150). So the
  lever is confirmed still the largest, and slightly larger than the ~729
  the const-alias round measured before today's other two rounds landed.

  ADMISSION, and why it reuses the MONO registry rather than inventing
  uniqueness checking. A bare name N is admitted only when `@registry[N]`
  holds EXACTLY ONE `MethodDef` -- verbatim `monomorphic_target`'s own test,
  against the same closed-world registry, so nothing new is trusted. That
  one test does all the heavy lifting: `extract_native_method_names` already
  puts a second, irep-nil `MethodDef` in the list for any name mruby's own C
  core or `mruby-rgss/src` also registers, so every genuinely polymorphic
  name refuses itself with no special case -- `size` (6 defs), `length`,
  `min`, `max`, `%`, `&`, `to_i`, `abs` are all out on that gate alone.

  Then, STRICTLY STRONGER than the MONO test: N must appear nowhere in the
  new `foreign_method_names` scan over `FOREIGN_RUBY_SRCS`
  (`foreign_mrblib_srcs`, compiled_gems.rb). `build_registry` reads only
  `closed_world_mrblib_srcs` plus the native name scan, so a method defined
  in `3rd/mruby/mrblib` -- real Ruby, compiled into the very same VM -- is
  invisible to it, and a name can look MONO while a second, completely
  different body really exists. That gap is tolerable for the direct calls
  this file already emits (a wrong MONO is a visibly wrong call, and the
  arity cross-check at `monomorphic_target`'s call site catches the
  realistic collisions); it is not tolerable here, because a wrong
  return-type proof emits a bare `mrb_fixnum()` with no runtime check and no
  `mrb_funcall` arm at all -- undefined behavior, the one failure mode this
  whole effort has avoided every round. Real collisions the scan catches in
  this repo, found by measuring rather than assuming: `size`
  (`mruby-enumerator/mrblib/enumerator.rb`'s own `def size`, which returns
  `@size` and is very often nil), `max`/`min` (`mrblib/enum.rb`, which
  return whatever the collection holds), `abs` (`mruby-complex`, a Float).
  The scan is textual and deliberately over-broad the same way
  `IntegerConstants.foreign_const_names` is -- `def`/`attr_*`/`alias`/
  `alias_method`/`define_method` -- because over-collecting only ever costs
  a proof. It is a POISON source layered on the registry's own uniqueness
  test, never positive evidence, which is why a fully dynamic definition it
  cannot enumerate (`alias_method :"string_#{v}", v`, 3rd/mruby-onig-regexp)
  does not undermine it.

  RETURN SITES. Every `RETURN` in the admitted body is checked, not the
  textually last one, and its register must pass this same
  `proven_fixnum_operand?` against the callee's own irep and `MethodDef`.
  `RETURN_BLK`/`BREAK`/`RETSELF`/`RETNIL`/`RETTRUE`/`RETFALSE`/`STOP` are
  each an immediate refusal, so `return nil` cannot slip past -- and it
  really does fire: `lower_index`, `equip_slot_for`, `damage` and
  `next_level_exp` are all rejected on a real `RETNIL` they genuinely
  execute. A body with catch handlers is refused outright (a rescue arm is
  an extra return path, and `RESCUE_SUPPORT` extracts that range into a
  separate function with re-initialized registers). Child ireps are NOT
  refused wholesale: the one thing that would make a nested body dangerous
  for an operand proof, a `SETUPVAR` write to an enclosing register, is
  already handled by `fixnum_proof_ctx`'s own `subtree_upvar_written_regs`
  at any depth. What is specific to a return analysis is a non-local exit
  written inside a nested body -- `def f; ary.each { return "x" }; 1; end`
  really does return a String and only the child irep holds the
  `RETURN_BLK` saying so -- so any descendant `RETURN_BLK` (and `BREAK`
  with it, one step more conservative than needed) refuses the method.
  Honest accounting: that refinement admits exactly one extra name
  (`Game::Map#substitute_tile`, two `each` blocks, neither exiting) and
  removes zero additional call sites over a blanket child-irep refusal.

  `SENDB`/`SSENDB` are deliberately absent from the proof source. A
  block-carrying send does not necessarily yield its callee's return value
  at all: a real `break` in the caller's own block hands the `BREAK` operand
  straight back as the send's result, so `ary.each { break "x" }` evaluates
  to `"x"` whatever `each` returns. The four admitted opcodes structurally
  cannot carry a block -- `3rd/mruby/src/codedump.c` prints them from
  separate `CASE(OP_SEND, BBB)`/`CASE(OP_SEND0, BB)`/`CASE(OP_SSEND, BBB)`/
  `CASE(OP_SSEND0, BB)` arms, distinct from `OP_SENDB`/`OP_SSENDB` -- so
  there is no break path to miss.

  A GREATEST fixpoint, and why that is sound here. Start from every
  candidate, repeatedly drop any whose return sites stop proving, until
  stable. This admits self- and mutual recursion, which a least fixpoint
  never could. The induction is on the DYNAMIC CALL TREE of one completed
  call, not on the graph's shape: for any call to an admitted N that
  actually RETURNS, its returned register was written by a classified
  source; all but the SEND arm are Fixnums outright by sources 1-5, and the
  SEND arm is a call to an admitted name that itself completed and returned
  strictly earlier in that same finite tree, so by hypothesis it returned a
  Fixnum. A cycle with no base case never returns at all (SystemStackError),
  so it is vacuous -- the same structure as the NameError step that makes
  `IntegerConstants`' own greatest fixpoint safe.

  A second admission variant, worth 27 of the 38 sites: a MONO
  `attr_reader`/`attr_accessor` whose ivar `IvarLayout` proved embeddable as
  `:fixnum`. There is no bytecode body to read return sites from
  (`kind: :ivar_accessor` means `irep` is nil), and none is needed -- this is
  proof source 3's own argument moved from the caller's `GETIV` to the
  callee's return. `drop_unsafe_embeddings` only ever leaves such a name
  embedded when `ATTR_STRUCT_DEVIRT` replaces that plain native accessor
  PROGRAM-WIDE with `emit_ivar_accessor_pair`'s synthesized struct-aware
  getter (`mrb_define_method` overwrites the class's whole method-table
  entry, so `send`, reflection and an unprovable receiver all land there
  too), it records the `:reader` override in `@synthesize_accessor_for`, and
  `synthesizable_accessor_only?` guarantees no other native body exists for
  that name on that owner. Verified against the real regenerated output
  rather than reasoned about: `LCF__EventCommand_code_impl` is literally
  `return mrb_fixnum_value(((LCF__EventCommand_ivars*)DATA_PTR(self))->code);`
  over an `mrb_int` field. The ten names are `animation_speed`,
  `animation_type`, `class_id`, `code`, `encounter_total`, `indent`,
  `level`, `save_count`, `selected_id`, `style`.

  The eighteen bytecode-proven names, each checked against real source, not
  counted: `actor_sprite_z` (`200 + i`), `dir4`, `dir8`, `flash_end`,
  `force_event_route`, `reset_frame_steps`, `reset_gauge`,
  `restore_substitutions`, `restore_tint`, `shake`, `shake_begin`,
  `shake_end`, `span` (`@frames - 1`), `start_gauge_action`,
  `start_round_animation`, `substitute_tile` (`@revision += 1`), `tint_to`,
  `value_font_color` (`return 5` / `return 4` / `0`, every arm a literal).

  WHAT THE CEILING IS ACTUALLY MADE OF -- the part worth carrying forward,
  since it says a future round should NOT simply push harder here. Splitting
  all 1249 costly SEND refusals by what the registry says about the target
  name: 401 MONO-bytecode, 265 MONO-native (mostly `:ivar_accessor`), 500
  genuinely POLY, 83 with no registry entry at all. A ceiling run over just
  the 56 distinct MONO-bytecode names removes 197 sites, so the whole
  MONO-bytecode direction is worth 197 of the 783, and the 38 shipped here
  are what actually PROVES out of it. The gap was diagnosed instruction by
  instruction rather than guessed at, and it is almost entirely real
  refusals of methods that genuinely do not return a Fixnum, or that fail on
  a DIFFERENT proof source:
  - `LCF::EventCommand#param(i)` is `@parameters[i] || 0` -- the single
    biggest name at 146 costly refusals, and correctly refused: the
    `JMPIF`/`LOADI_0` join means the other arm returns whatever the array
    holds. `item_count` (`@items[id] || 0`), `state_field`, `price`,
    `step_cost` and `battle_status_x` are all the same shape.
  - `recover_cap`/`damage_cap`/`editor_digits` are `cond ? CONST_A : CONST_B`
    -- both arms proven integer constants, refused only by the known,
    already-documented if/else-join dominance gap (the walk takes the
    nearest reaching definition, not all of them).
  - `seconds`, `lower_index`, `cand_col_w`, `item_col_w` and `rows` all
    return a `DIV` result, which the header has deliberately declined as a
    proof source since the original round (`mrb_div_int_value`'s return type
    is unaudited across bigint/overflow configurations). `DIV` separately
    measures 198 COSTLY refusals in its own right.
  - the rest are `GETIV` of an ivar with no proven embedding
    (`@row`, `@height`, `@event_id`, `@openness`), or a nested SEND to a
    POLY/native name (`:max`, `:%`, `:clamp`, `:-@`).
  So the 783-site SEND ceiling is not a return-type-inference backlog. It is
  mostly the OTHER refusal categories reached one call deeper, and a future
  round gets far more out of `GETIDX`/element typing, `DIV`, or the
  if/else-join dominance case than out of extending this mechanism.

  Deliberately NOT done, measured rather than hand-waved. A curated
  native-method allowlist (`Array#size`/`String#length` and friends) was
  scoped and declined: `size`+`length` alone measure 112 sites at ceiling,
  materially more than this whole change, but both names are POLY in the
  registry and defined in foreign mrblib, so admitting them means abandoning
  the bare-name unanimity this proof rests on and resolving the receiver's
  class at each site instead -- a different mechanism with its own soundness
  argument, not an extension of this one. The neighbouring names are worse,
  not better: `%` (91 costly, the largest native name) is `String#%`
  returning a String as readily as `Integer#%` returning a Fixnum; `&` is
  `Array#&` returning an Array; `to_i` and `abs` return an Integer that is
  not closed over Fixnum under `MRB_USE_BIGINT`. None is name-keyable and
  each would need per-receiver proof.

  Verification: `ruby -c` clean; `scripts/rpg2k_logic_check.rb` (1201),
  `scripts/rpg2k_scene_check.rb` (1062) and `scripts/lcf_testbed_check.rb`
  all pass with identical counts. A real `g++ -std=c++17 -fsyntax-only` pass
  over the whole generated `SKIP_UNSUPPORTED=1` translation unit reports the
  same 17 pre-existing, unrelated errors as the baseline and zero new ones
  (12 `could not convert '1' from 'int' to 'mrb_value'`, 5
  `RPG2k::Scene::Map#vehicle_blocks` arity) -- diffed as error-text
  multisets between baseline and new output, not compared by count. In
  `docs/bc2cpp_coverage.txt` the only lines that move are the new
  FIXNUM_RETURN_PROOF count, the call-site total (14933 -> 14895), its
  non-POLY half (8687 -> 8649) and the four per-operator entries above;
  compiled entry points (2286), method-level coverage (98.6%), the `#error`
  total (50), POLY-marked sites (6246), distinct dispatched names (1033) and
  the BLOCK_FALLBACK/LAMBDA_FALLBACK counts are all byte-identical. The
  committed baseline was first confirmed to regenerate byte for byte with
  `3rd/mruby` and its sibling gems checked out, since an uninitialized
  submodule empties `NATIVE_SRCS` and silently breaks exactly the registry
  uniqueness test this change depends on.
