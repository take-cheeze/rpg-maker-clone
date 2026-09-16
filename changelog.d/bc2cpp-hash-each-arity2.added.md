- `tools/bc2cpp/bc2cpp.rb` can now inline `hash.each { |k, v| ... }`
  (new `recognize_hash_each_regions`/`emit_hash_each_inline`, gated on a
  receiver proven `Hash` via the same `trace_new_target`/`ClassLayout`
  machinery the Array recognizers already use -- including this round's
  own new constant-resolution and `HASH` literal terminals) -- previously
  every `Hash#each` call site stayed `#error unhandled opcode BLOCK`/
  `SENDB` unconditionally, the same gap the earlier typing-coverage
  survey identified as one of the three real, orthogonal reasons most
  `BLOCK`/`SENDB` sites can't yet inline.

  Real `Hash#each` (`3rd/mruby/mrblib/hash.rb`) snapshots `keys`/`vals`/
  `size` once before iterating (not a live hash-table walk), so the new
  emitter mirrors that exactly with `mrb_hash_keys`/`mrb_hash_values`/
  `mrb_hash_size` (all real public `MRB_API`, `mruby/hash.h`, already
  unconditionally included) feeding a bounds-checked index loop, rather
  than `emit_each_inline`'s own live `RARRAY_LEN` re-check -- there is no
  live hash left to re-check against once two already-snapshotted Arrays
  exist. The two synthesized values (key, value) are assigned directly
  into the block's own `R1`/`R2`, the same "skip the real `Proc#call`/
  auto-splat machinery, just assign the registers" mechanism
  `recognize_accum_regions`' own `reduce`/`inject` fold already uses for
  its own 2-value yield. No real bytecode override of `Hash#each` exists
  anywhere in this closed world (confirmed: no `class Hash` reopen, no
  `class X < Hash`, in any of mruby-rpg2k/mruby-lcf/mruby-rgss's own
  mrblib), so a proven-`Hash` receiver is unambiguous.

  A real, previously-latent bug in the SHARED block-region framework was
  caught and fixed along the way, found only by actually compiling the
  generated output with `g++ -fsyntax-only` (bc2cpp.rb's own `#error`-
  marker diagnostics can never catch this class of bug -- the emitted
  C++ is syntactically well-formed everywhere except one missing label):
  `compile_method`'s own `targets = jump_targets(irep) - suppressed`
  also dropped the label for any address that is suppressed but still
  has real glued replacement code sitting at it, which a `BLOCK`
  region's own `block_addr` can be whenever it's *also* a genuine jump
  target from elsewhere in the same method -- e.g. `(h[:x] ||
  {}).each { ... }`, whose `||` short-circuit lands directly on the
  `.each` call's `BLOCK` instruction. Fixed by excluding only
  `glue_at`-less suppressed addresses (`suppressed - glue_at.keys`).
  Confirmed pre-existing and NOT specific to this round's own changes:
  the same bug, with the same root cause, already affects
  `recognize_collect_regions`' real, currently-shipped
  `Game::Actor#states=` (its own `ids.reject { ... }` region) on master
  today -- this round's own Hash#each work simply happened to be the
  first to hit a real call site combining "receiver expression with a
  preceding short-circuit landing exactly on the block address" and
  notice it. Every other block recognizer shares this exact machinery
  and benefits from the same fix.

  Verified via a real whole-program regen diff: compiled entry points
  1963 -> 1965 (+2 fully-clean methods; 14 real `BLOCK`/`SENDB` call-
  site pairs newly inlined in total, most inside otherwise-still-
  `#error`ed methods), coverage 85.0% -> 85.1%, `unhandled opcode BLOCK`
  380 -> 366, `SENDB` 357 -> 343.
  Independently verified with a real `g++ -std=c++17 -fsyntax-only`
  compile of the actual `SKIP_UNSUPPORTED=1` generated output (the same
  shape a real gem build produces): zero `label ... used but not
  defined` errors, down from 27 pre-existing ones on unpatched master
  (all from the same shared-framework bug, none specific to this
  change) plus the 6 this change's own newly-inlined Hash#each regions
  would otherwise have added. The only errors remaining afterward are
  six pre-existing, unrelated `int` -> `mrb_value` conversion errors in
  `anim_target`/`command_item` (a default-argument-value codegen gap,
  out of scope here) and a pre-existing missing `#include
  <mruby/numeric.h>` for `FIXABLE_FLOAT`/`mrb_integer_to_str` (`to_i`'s
  own Float case, PR #1718) -- neither touched by this change.
  `scripts/rpg2k_logic_check.rb` (1201 checks), `scripts/
  rpg2k_scene_check.rb` (1062 checks), `scripts/lcf_testbed_check.rb`
  all still pass.
