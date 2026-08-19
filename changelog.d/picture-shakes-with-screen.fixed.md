- **Pictures (Show Picture):** A picture not fixed to the map now shakes
  along with a Shake Screen effect, matching RPG_RT. Previously only a
  map-fixed picture happened to shake (a side effect of the map-scroll
  offset already including the shake), while the far more common
  "not fixed to map" default held rock-steady — a full-screen "impact"
  graphic, a portrait during dialogue, or a HUD element sat still while
  everything else on screen visibly jittered. Covered by a new
  `scripts/rpg2k_scene_check.rb` check.
