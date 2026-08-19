- **Field menu:** Choosing a currently unusable skill (out of SP, or sealed
  by a Silence/Seal-type state) in the field Skill menu now just buzzes and
  stays on the list, matching RPG_RT -- previously it still played the
  Decision sound and opened the full target-confirm screen (or cast a switch
  skill outright), only reporting "It had no effect." afterward. Covered by
  a new `scripts/rpg2k_scene_check.rb` check.
