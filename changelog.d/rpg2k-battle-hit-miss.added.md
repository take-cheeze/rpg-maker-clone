- RPG Maker 2000: **basic attacks can now miss**. `Game::Battle#to_hit` computes
  an attacker's to-hit percentage from its base hit rate — an actor's equipped
  weapon `hit` (`Game::Actor#attack_hit_rate`, unarmed default 90), an enemy's 90
  or 70 when the database "miss" flag is set (`Game::Enemy#attack_hit_rate`) —
  adjusted by the attacker/target agility ratio, matching EasyRPG's
  `CalcNormalAttackToHit` / `CalcToHitAgiAdjustment` (which reduces to
  `100 - (100 - base)·(srcAgi + tgtAgi)/(2·srcAgi)`, clamped 0..100), so a nimbler
  target dodges more. The base hit rate is snapshotted onto the `Combatant`, and
  `deal_attack` rolls it when the fight has accuracy enabled — a miss deals no
  damage and tags the log entry `missed: true` (the battle screen banners "X
  misses Y"). Accuracy is an opt-in `Game::Battle` flag the live game turns on,
  off by default so seeded / headless fights stay reproducible. Covered by new
  `scripts/rpg2k_logic_check.rb` checks (the to-hit formula and its clamps,
  accuracy-off always connects, a sure-miss deals no damage, and the roll both
  lands and misses over many swings).
