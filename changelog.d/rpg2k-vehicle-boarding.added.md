- **Vehicle boarding and piloting.** The party can now board a placed vehicle and
  pilot it around the map. Pressing the action button while standing on a vehicle
  (the airship) or facing one across the shore (a boat / ship) boards it and steps
  the party onto its tile; pressing it again steps off onto the walkable tile
  ahead, leaving the vehicle behind. While aboard, movement uses the vehicle's
  passability — the **airship flies over any tile** (including those blocked on
  foot), while a **boat / ship follows its terrain** (the database terrain's
  `boat_pass` / `ship_pass` flag, falling back to on-foot passability where the
  map has no terrain data) — and the vehicle tracks the party's position and
  facing. The ridden vehicle is recorded on `Game::State` (`boarded` /
  `boarded?`) and persists through the save. Still to come: drawing the vehicle
  and the ridden party on the map, the vehicle's own BGM, airship landing
  restrictions and its ground shadow, and writing the ridden flag into the LSD
  save. Covered by new checks in `scripts/rpg2k_logic_check.rb` (the ridden
  vehicle round-trips through the save) and `scripts/rpg2k_scene_check.rb`
  (boarding a boat then disembarking onto the shore; the airship crossing an
  on-foot-blocked tile and following the party).
