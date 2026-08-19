- **Map events:** The action button now also answers a same-layer Player
  Touch or Event Touch NPC standing one tile ahead, not just an Action
  (trigger 0) event -- previously such an NPC could only be reached by
  physically walking onto its tile, matching RPG_RT's own unconditional
  touch-trigger check on the faced tile. Covered by three new
  `scripts/rpg2k_scene_check.rb` checks.
