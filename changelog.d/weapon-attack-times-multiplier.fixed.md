- **RPG2003 battles:** A weapon's per-actor Battle Animation "Number of
  Attacks" (攻撃の回数) setting now multiplies a basic Attack's swing count,
  matching RPG_RT -- previously only 二刀流 (`dual_attack`) affected swing
  count, so this field did nothing at all. Covered by a new
  `scripts/rpg2k_logic_check.rb` check.
