- **Airship landing and fly-over restrictions.** The airship now reads the two
  terrain flags Set Vehicle Location left unused: `airship_pass` (a tile it may
  fly over at all) and `airship_land` (a tile it may set down on), both default
  true so ordinary maps behave exactly as before. Flying now checks
  `airship_pass` through the same `vehicle_passable?` a boat / ship already used
  for `boat_pass` / `ship_pass`, instead of the airship unconditionally clearing
  every in-bounds tile. Disembarking the airship changed to match RPG_RT: it
  lands **in place** — testing `airship_land` (and that no event sits on the
  ground below) under the party's own tile — rather than stepping onto the tile
  ahead the way a boat / ship disembarks onto the shore; landing where the
  terrain forbids it leaves the party aboard. This was the one piece explicitly
  left for later when vehicle boarding first landed. Covered by three new
  checks in `scripts/rpg2k_scene_check.rb`: an `airship_pass: false` terrain
  grounds the airship in place, an `airship_land: false` terrain refuses to let
  the party disembark, and the default (both true) still lands normally.
