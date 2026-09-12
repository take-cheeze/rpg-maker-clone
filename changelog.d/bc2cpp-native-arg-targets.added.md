- `tools/bc2cpp/bc2cpp.rb` now has a third, additive native-calling-
  convention mechanism (alongside `NATIVE_CONSTRUCT_TARGETS`/
  `DIRECT_CONSTRUCT_TARGETS`'s own construction-only ones): `NATIVE_ARG_TARGETS`,
  an explicit, human-vetted "Owner#name" allowlist that moves an ordinary
  compiled method's own mandatory argument off `mrb_value` and onto a real
  native `mrb_int`/`mrb_sym`, generalizing the just-shipped Rect/Color/Tone
  round's own signature relocation from three hand-written native
  constructors to ordinary bc2cpp-compiled `_impl` functions. The trigger is
  a real, human-authored `# bc2cpp: (fixnum, ...)` magic-comment annotation
  on that exact position -- never `ArgTypes`' own passive, call-site-inferred
  typing, which only ever observes what today's callers happen to pass, not
  a declared intent (see that constant's own comment for the full soundness
  argument). The entry wrapper's `mrb_get_args` format character becomes the
  real coercing `"i"`/`"n"` (instead of `"o"`, no coercion) for that
  position, and every real MONO/TYPED devirtualized call site elsewhere in
  the compiled program unboxes its own argument with `mrb_as_int`/
  `mrb_obj_to_sym` right there -- the identical "move the callee's own
  internal coercion to the call site" pattern that round already
  established, generalized from a hardcoded native constructor to an
  ordinary devirtualized call. Deliberately conservative about scale: 9 real
  methods across `Game::Actor`/`Game::Interpreter` (`gain_exp`,
  `change_level_by`, `change_mp`, `exp_for_level`, `free_two_handed_slot`,
  `slot_cursed?`, `base_param_limit`, `character_ref`, `trunc_div`), each
  individually traced through every real call site in the regenerated
  output and checked for a defensive `nil?` guard on the annotated argument
  that would make a native-typed boundary a real behavior regression (two
  otherwise-eligible candidates, `Game::Actor#knows_skill?`/`#learn_skill`,
  were found to have exactly that shape and deliberately excluded) --
  see the constant's own comment for the full per-method writeup.
