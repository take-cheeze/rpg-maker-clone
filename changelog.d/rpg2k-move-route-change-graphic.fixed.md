- **A Set Move Route "Change Graphic" targeting the hero now actually changes
  what's drawn.** RPG_RT lets a move route override a character's on-screen
  CharSet graphic in place, distinct from the dedicated Change Hero Graphic
  command: it applies immediately, but it isn't persistent — it reverts on
  Transfer Player (and, being scene-only state, on save/load too). This build
  already applied the sub-command to the forced-route mirror character
  (`@player_char`), but the renderer (`draw_player_frame`) always drew the
  party leader's own `@charset`/`@charset_index` and never looked at it, so
  the override had **no visible effect at all** for the hero. It now reads
  `@player_char`'s overridden graphic when a route has changed it (reusing
  the existing per-name CharSet cache map events already use), falling back
  to the leader's own graphic otherwise, and `perform_teleport` clears
  `@player_char` so the override reverts on Transfer Player. Covered by a new
  check in `scripts/rpg2k_scene_check.rb`.
