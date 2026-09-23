- **A devirtualized attr_reader/attr_writer on a class that embeds that ivar
  now reads and writes the embedded field.** bc2cpp moves a wired class's
  proven-typed ivars into its RData struct and synthesizes the matching
  accessors, which the POLY accessor chain already called. The
  LEXICAL_SELF_IVAR_ACCESSOR and IVAR_ACCESSOR devirtualizations still emitted
  a bare `mrb_iv_get`/`mrb_iv_set`. Those read nil from the ivar table, and
  their writes never reached the struct. 16 embedded ivars were affected,
  at 61 call sites, including `Game::Actor#id`/`#level`/`#class_id`,
  `Game::Party#gold`, `Game::Enemy#hidden`, the `Game::MessageConfig` face
  and position settings, and `Game::State#bgm_looped`. The boot check's
  RPG2003 battle failed with "nil cannot be converted to Integer" in
  `Game::Actor#weapon_attack_multiplier`. Both paths now call the synthesized
  accessor, or stay dynamic when it is not in scope.
  `scripts/bc2cpp_wired_embedding_check.rb` now fails any accessor site that
  goes to the ivar table for an embedded field.
