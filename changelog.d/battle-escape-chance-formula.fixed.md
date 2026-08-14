- **The battle escape-chance roll now matches EasyRPG's
  `Scene_Battle::InitEscapeChance()` / `TryEscape()` exactly.** Three
  divergences from the real `150 - 100·enemyAgi/partyAgi` formula are fixed
  together: a fallen battler is now still counted in its side's average
  agility (EasyRPG's `Game_Party_Base::GetAverageAgility()` sums over every
  member, not just the living ones — `Game::Battle#avg_agi` used to `reject`
  the dead, understating the average the moment anyone went down); the
  agility ratio is now rounded to the nearest percent rather than truncated
  (`InitEscapeChance` finishes with `Utils::RoundTo<int>`/`std::lrint`, while
  this build did a plain integer divide — a 7-agi party against a 10-agi
  troop should read escape chance 7, not 8); and the chance is now computed
  once, at battle start (`Game::Battle#initialize`), instead of lazily on
  the first Flee attempt, matching `Scene_Battle::Start()` calling
  `InitEscapeChance()` exactly once before any turn runs, so a stat-altering
  status landing mid-fight no longer skews an escape chance that real
  RPG_RT fixed before the first round. Covered by three new
  `scripts/rpg2k_logic_check.rb` checks, confirmed to fail against the
  pre-fix code before the fix.
