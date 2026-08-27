- `Game::State#to_lsd` now writes chunks 105/106/107 (boat/ship/airship
  vehicle locations) unconditionally, instead of omitting a vehicle's
  record entirely until it had been placed on a map at least once.
  Confirmed against a genuine kk1.12 save under wine, taken in a session
  where the party never boarded any vehicle at all: all three chunks were
  still present, each with `map_id`/`x`/`y` at the never-placed sentinel
  (0), and each carrying RPG_RT's own built-in defaults this codebase
  previously only produced once a vehicle had actually been positioned —
  `direction` (facing left, not the arbitrary "down" `Game::Vehicle` used
  to default to), `charset_name` ("乗り物", RPG_RT's built-in vehicle
  sprite), `charset_index` (0/1/3 for boat/ship/airship, elided at 0 like
  every other zero-default field in this schema), and `move_speed` (4/4/5,
  the airship being the one built-in exception). Also adds liblcf's own
  `SaveVehicleLocation.vehicle` field (101, the vehicle's own 1/2/3
  ordinal) to `mruby-lcf/mrblib/schema.rb`'s shared `SAVE_MOVABLE` table,
  confirmed present on the same capture. The remaining gap in these three
  chunks (liblcf's `layer` and an in-progress move route) is the same
  already-documented gap `SAVE_MOVABLE`'s own comment calls out for the
  hero's chunk 104 record — left for a future cycle.
