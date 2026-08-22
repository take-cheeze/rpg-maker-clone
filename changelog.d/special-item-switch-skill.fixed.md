- **Field items:** A special (type 9) or `use_skill`-flagged equipment item
  invoking a Switch-type skill now actually flips its switch and closes the
  menu, matching RPG_RT -- previously it reported "It had no effect."
  every time, since it fell through to logic with no notion of switches at
  all. Covered by new `scripts/rpg2k_logic_check.rb` and
  `scripts/rpg2k_scene_check.rb` checks.
