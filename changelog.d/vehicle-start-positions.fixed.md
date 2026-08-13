- **A boat, ship or airship the map tree gives its own starting position now
  places there at New Game**, instead of staying unplaced until an event runs
  Set Vehicle Location. RPG2000's editor has a dedicated "set starting
  position" tool for each vehicle (the map tree's `initial` chunk, fields
  11-13 / 21-23 / 31-33: `boat_map_id`/`x`/`y`, `ship_map_id`/`x`/`y`,
  `airship_map_id`/`x`/`y`), parsed by the schema and never read anywhere in
  `mruby-rpg2k` — `Game::Vehicle.new` always defaulted to `map_id: 0`
  ("unplaced"), and the only place any vehicle's location was ever written was
  the Set Vehicle Location (10850) event command or a save load. A game that
  relies on the tree's own default position for a vehicle it never explicitly
  places would show that vehicle nowhere, ever. Fixed with a new
  `Game::State#seed_vehicle_positions(map_tree)`, mirroring
  `#seed_screen_transitions`'s shape, called once from `RPG2k#start_new_game`
  right beside the identical seeding already done for the hero's own
  `initial_map_id`/`x`/`y` — Continue does not call it, since a vehicle's
  saved position (from this seeding or a later Set Vehicle Location) already
  round-trips through `Vehicle#to_h`/`#load_h`/`#load_movable`. A vehicle
  field the tree leaves unset keeps `Vehicle.new`'s own unplaced default.
  Covered by two new `scripts/rpg2k_logic_check.rb` checks (each vehicle
  places at its own tree-configured position; one the tree never positions
  stays unplaced), confirmed to fail against the pre-fix code before the fix.
