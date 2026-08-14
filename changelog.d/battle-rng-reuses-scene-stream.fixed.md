- **A battle's own combat math (hit/miss, criticals, damage variance, enemy
  AI, escape chance, item drops) now draws from the same continuously-
  advancing RNG stream as the rest of the game session, instead of
  restarting from the same fixed point every single fight.** Real RPG_RT
  runs one PRNG stream for the whole session, never reseeded mid-game; this
  engine's `Scene::Map#open_battle` instead built each fight's `Game::Battle`
  on a brand-new `Game::Rng.new(0x2000)`, discarding the scene's own
  already-advancing `@rng` (the same stream random-encounter checks and NPC
  wandering already draw from). Two battles against the same troop, given
  the same player inputs, played out byte-identical no matter how far apart
  in the playthrough they happened. Fixed by threading the scene's own
  `@rng` into `Game::Battle.new` in place of the disposable one; the
  scene's own dedicated deterministic RNGs (used for the wine-diff
  regression methodology) are untouched.
