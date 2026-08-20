- **Level-up stats were reading the wrong entries of the growth curve for
  every stat but max HP, at every level but 1.** `Game::Actor#base_stats`
  treated an actor's (or RPG2003 class's) chunk-31 parameter curve as six
  shorts interleaved per level (`maxhp, maxsp, atk, def, int, agi` for level
  1, then the same six for level 2, ...). liblcf's own reader,
  `RawStruct<rpg::Parameters>::ReadLcf` (`src/ldb_parameters.cpp`), instead
  reads six *separate* same-length runs back to back: every level's maxHP,
  then every level's maxSP, then atk/def/int/agi. Reading it the old way
  landed on a different stat's value for every level past the first — a real
  database's (Nepheshel) level-1 ATK read as 59, which was actually the
  level-3 entry of the maxHP run — inflating combat stats (and so basic-attack
  damage) well past what real RPG_RT computes from the same file. `base_stats`
  now slices the curve into `curve.size / 6` same-length blocks and indexes
  `block[stat] [level - 1]`, matching the reference reader. The hand-built
  growth-curve fixtures across `rpg2k_logic_check.rb` were rewritten from
  interleaved rows to the same block layout via a new shared `block_curve`
  test helper. See ADR 0015's follow-up note.
