- RPG Maker 2000: **basic attacks now vary their damage**. `Game::Battle` gains
  an opt-in `variance` flag; when set, each basic attack spreads its base damage
  by RPG2000's normal-attack variance (a `var` of 4 — an adjustment of
  `var*base/10`, min 1, centred on the base with a random offset and floored at
  1), a port of EasyRPG's `Algo::VarianceAdjustEffect`. `Scene::Map` turns it on
  for the live game, so two hits from the same attacker differ; it stays **off by
  default** so seeded / headless fights remain exactly reproducible and the
  existing battle checks are unaffected. Covered by new
  `scripts/rpg2k_logic_check.rb` checks (a hit lands within its computed spread,
  the spread is seed-deterministic and varies across many hits, and a
  variance-off fight still deals exactly the base damage). Skill / item damage
  variance and criticals remain follow-ups.
