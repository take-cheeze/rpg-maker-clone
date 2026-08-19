- **Battles:** A Skill's own damage, defence term, and RPG2003 physical-style
  accuracy formula now read the caster's/target's currently-active ATK/DEF/
  SPI/AGI buff or debuff, matching RPG_RT -- previously only a basic Attack
  honored it, so a second skill cast against an already-weakened (or
  already-buffed) battler computed its effect off the unmodified base stat.
  Covered by a new `scripts/rpg2k_logic_check.rb` check.
