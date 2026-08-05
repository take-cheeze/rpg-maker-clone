- RPG Maker 2000: **defeated enemies now drop their treasure items** on victory.
  `Game::Enemy` reads the database `drop_id` / `drop_prob` fields, and the new
  `Game::Troop#drops(rng)` rolls each member's drop probability as a percentage
  (0..99 < prob, per EasyRPG's `Rand::PercentChance`) — a 100% drop is certain, a
  0% never lands, and the same item can drop from several members. The battle
  result screen grants the rolled items to the party bag (on the battle's own
  RNG) alongside the EXP and gold, naming each in the victory window. Covered by
  new `scripts/rpg2k_logic_check.rb` checks (the drop fields are read, certain
  drops land while zero-chance / item-less foes are skipped, and the probability
  actually gates the roll).
