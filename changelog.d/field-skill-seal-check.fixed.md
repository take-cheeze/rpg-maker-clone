- **Field menu:** A Silence/Seal-type status now blocks casting a sealed
  skill from the field Skill menu too, matching RPG_RT -- previously the
  seal (`restrict_skill`/`restrict_magic`) only bit inside a battle, so a
  persistent seal state left the field cast wide open. Covered by a new
  `scripts/rpg2k_logic_check.rb` check.
