- RPG Maker 2000: states can now **halve or double a battler's stats**. A
  state's `affect_type` (0 halve / 1 double / 2 no change) plus its four
  independent `affect_attack` / `affect_defense` / `affect_spirit` /
  `affect_agility` flags say which stat(s) it touches — both left unread
  before this. `Battle#effective_atk` / `#effective_def` / `#effective_spi` /
  `#effective_agi` (EasyRPG's `Game_Battler::AdjustParam`, minus its
  battle-only stat-`mod` term) feed basic-attack and self-destruct damage,
  the to-hit agility term, average agility (so escape chance answers it too)
  and turn order, so a Weaken-style state that halves ATK now actually softens
  a hit, and two states that cancel out (one halving, one doubling the same
  stat on the same battler) net to no change, matching `AdjustParam`'s own
  `dbl != half` guard. Left scoped out on purpose: a battle Skill's power
  formula still reads a battler's plain stats rather than the state-adjusted
  value, noted in `docs/TODO.md` as a follow-up rather than silently
  inconsistent. Covered by new `scripts/rpg2k_logic_check.rb` checks.
