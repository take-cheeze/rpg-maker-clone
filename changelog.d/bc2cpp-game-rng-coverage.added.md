- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 3 of
  `Game::Rng`'s own 4 real bytecode methods (the engine's own seeded
  linear-congruential PRNG, used wherever the original RPG_RT's own
  randomness needs to match, e.g. enemy encounter rolls): `#next_int`,
  `#random`, `#scaled`. Added to `mruby-rpg2k-compiled`, needing zero new
  opcode work and finding zero live `bc2cpp.rb` bugs. `#initialize` (one
  optional argument) stays interpreted, the same established
  non-mandatory-arity gap as every other unembedded target, so its one
  real ivar (`@state`) stays on the ordinary dynamic `iv_tbl`. As a side
  effect of whole-program devirtualization, `RPG2k::Scene::VehicleWorld
  #random`'s own `@rng.random(n)` call (previously always ordinary
  `mrb_funcall` dispatch) now gets a real runtime-class-guarded direct
  call into `Game::Rng#random`'s own compiled body.
