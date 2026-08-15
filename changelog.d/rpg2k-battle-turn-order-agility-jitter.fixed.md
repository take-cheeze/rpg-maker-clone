- **Battle turn order now rolls a random Agility jitter each round, instead
  of sorting purely by raw Agility.** Confirmed against EasyRPG Player's
  source: `Scene_Battle_Rpg2k::CreateExecutionOrder` rolls `agi + Rand(0,
  agi / 4 + 3)` fresh for every battler each round before sorting. This
  engine sorted by raw Agility alone, with a fixed tie-break rule (ally
  before enemy, then lower actor id) that doesn't exist in the real game —
  RPG_RT resolves agility ties via the random roll instead, so two battlers
  with equal Agility (a common case for a balanced fight) previously acted
  in the exact same order every single round of every battle, rather than
  either potentially going first as in the original game.
