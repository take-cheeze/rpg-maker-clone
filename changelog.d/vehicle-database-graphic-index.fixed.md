- **An uncustomized boat, ship or airship now draws the database System
  boat_index/ship_index/airship_index cell**, instead of always drawing cell 0
  of its CharSet sheet. The System chunk stores each vehicle's on-map graphic
  as a filename *and* a cell index within it (`boat_name`/`boat_index`,
  `ship_name`/`ship_index`, `airship_name`/`airship_index`, System fields
  11-16), and EasyRPG Player's actual C++ source shows both are read together
  when a vehicle is built: `Game_Vehicle::Game_Vehicle`
  (`src/game_vehicle.cpp`) calls `SetSpriteGraphic(ToString(lcf::Data::system.
  boat_name), lcf::Data::system.boat_index)` (and the ship_/airship_
  equivalents). `Scene::Map#vehicle_charset` already fell back to the
  database's `*_name` field when a vehicle's own `charset_name` was never set
  (by Change Vehicle Graphic), but the sibling `#vehicle_charset_index` had no
  matching fallback for `*_index` — it read `Game::Vehicle#charset_index`
  directly, which stays `0` forever unless Change Vehicle Graphic (or a
  loaded save) writes it. Any game whose vehicle graphic sheet places the
  vehicle sprite at a cell other than 0 (a common CharSet layout, since a
  sheet holds several character frames) drew the wrong sprite for every boat,
  ship and airship that was never given an explicit graphic. Fixed by giving
  `#vehicle_charset_index` the same empty-`charset_name`-gated fallback to
  `@db.system.send("#{v.type}_index")` that `#vehicle_charset` already has for
  the name. Covered by a new `scripts/rpg2k_scene_check.rb` check (all three
  vehicle types fall back to their database index when uncustomized; an
  explicit Change Vehicle Graphic still keeps its own index, even index 0),
  confirmed to fail against the pre-fix code before the fix.
