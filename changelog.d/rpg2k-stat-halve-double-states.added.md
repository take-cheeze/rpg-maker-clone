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
  `dbl != half` guard. A battle **Skill**'s power formula
  (`Game::Party#skill_effect` / `#skill_defence_term`) reads it too, through
  `Party`'s own copy of the same logic against `@db.situation` — which also
  makes field/menu skill casting respect a caster's/target's states, not
  just in-battle skills, matching how EasyRPG's `GetAtk()` / `GetSpi()` are
  the one accessor every context reads through. Covered by new
  `scripts/rpg2k_logic_check.rb` checks.
