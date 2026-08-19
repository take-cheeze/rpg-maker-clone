- **Input Number:** The digit-entry cursor now starts on the rightmost
  (least significant) digit and wraps cyclically when pressing Left/Right,
  matching RPG_RT -- previously it started on the leftmost digit and clamped
  at either end. Covered by an updated `scripts/rpg2k_logic_check.rb` check
  and four corrected `scripts/rpg2k_scene_check.rb` integration checks.
