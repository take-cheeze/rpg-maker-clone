- `Game::State#to_lsd` now writes chunks 105/106/107 (boat/ship/airship
  vehicle locations) unconditionally, instead of omitting a vehicle's
  record entirely until it had been placed on a map at least once.
  Confirmed against a genuine kk1.12 save under wine, taken in a session
  where the party never boarded any vehicle at all: all three chunks were
  still present, each with `map_id`/`x`/`y` at the never-placed sentinel
  (0), and each carrying values (`direction`, `move_speed`, and liblcf's
  own `SaveVehicleLocation.vehicle` ordinal, a new field 101 added to
  `mruby-lcf/mrblib/schema.rb`'s shared `SAVE_MOVABLE` table) this codebase
  previously only produced once a vehicle had actually been positioned.
  `charset_name`/`charset_index` (fields 73/74) stay absent for an
  uncustomized vehicle exactly as before — that capture's own database
  happens to configure every vehicle's System boat/ship/airship name/index
  to the values seen there, and reproducing them here would require
  threading a database handle into `#to_lsd`, which does not have one
  today; a live Change Vehicle Graphic override (or one restored from a
  prior `.lsd`) still writes through as before. The remaining gap in these
  three chunks (liblcf's `layer`, an in-progress move route, and the
  database-sourced charset fallback above) is left for a future cycle.
