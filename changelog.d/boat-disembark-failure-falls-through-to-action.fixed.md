- **Vehicles:** Pressing the action button aboard a boat or ship that fails to
  disembark -- an NPC standing on the landing tile, for instance -- now falls
  through to the ordinary action-trigger check on that same tile instead of
  just swallowing the button press, matching RPG_RT. This lets a shore NPC be
  talked to directly from the boat. The airship is unaffected, since RPG_RT
  never runs that fallback while flying regardless. Covered by a new
  `scripts/rpg2k_scene_check.rb` check.
