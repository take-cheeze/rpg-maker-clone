- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 3 of
  `Game::Enemy`'s own 4 real bytecode methods (a single database-backed
  enemy combatant built for a battle): `#attack_hit_rate`, `#dead?`, and
  `#reseed_rewards`. Added to `mruby-rpg2k-compiled`, needing zero new
  opcode work and finding zero live `bc2cpp.rb` bugs. `#initialize` (three
  optional arguments) has the established non-mandatory-arity gap, so
  `drop_unsafe_embeddings` correctly refuses to embed any of this class's
  own thirteen provably-Fixnum ivars.

  Cross-checking `#reseed_rewards`'s own four POLY sends one by one
  against the real registry dump (not just the summary count) surfaced a
  real, confirmed-but-not-currently-live registry gap: `Game::Enemy`'s own
  15-Symbol `attr_reader` call (`:id, :name, :battler_name, ...`) compiles
  to mrbc's `SSEND ... n=*` splat encoding (the direct arg-count nibble
  maxes out at 14 -- confirmed against the one other attr_reader call
  project-wide that lands exactly on that boundary, which encodes fine at
  `n=14`), which the existing attr_reader/writer/accessor registry fix's
  `n=(\d+)` parse silently reads as 0, so none of those 15 real Enemy
  accessor names -- including three that collide with other real
  definitions elsewhere -- ever gets a registry entry for `Game::Enemy` at
  all. Checked each of the 15 names individually: every colliding
  definition on the other side is itself synthetic (`irep: nil`), and
  `monomorphic_target` already refuses to devirtualize into any target
  with a nil `irep` regardless of definition count -- so this gap is real
  but safe today for every name it actually touches. Not fixed in this
  round to avoid scope creep (`Game::Enemy`'s own three target methods
  compile clean without it) -- left as a documented, confirmed-safe
  structural gap for a future round. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.
