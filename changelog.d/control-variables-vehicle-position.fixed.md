- **Control Variables' character-position operand (type 6) now resolves a
  vehicle target (boat/ship/airship, ref 10002-10004)** instead of always
  reading 0 — the viprpg-dev wiki's "Vehicles" findings note a vehicle's
  x/y/screen-x/y can be read via variable ops even from a map other than the
  one it currently occupies. `Game::Interpreter#event_operand`
  (`mruby-rpg2k/mrblib/interpreter.rb`) only recognised the hero (ref 10001)
  and map event ids (1-9999); a vehicle ref fell through to the same "no
  match" branch a nonexistent map event does. A new `#vehicle_operand` reads
  the target `Game::Vehicle` straight off `Game::State` (map id, x, y,
  facing) — no scene hook needed, since (unlike a map event) a vehicle's
  position is tracked independently of whichever map is currently loaded,
  and `Scene::Map#follow_vehicle` already keeps a ridden vehicle's stored
  position live every step. Unlike a map event's own map-id read (a
  long-standing RPG_RT quirk that always answers 0), a vehicle's map id
  operand returns its real value, the same way the hero's own does. Screen
  x/y (attr 4/5) are unchanged — they still read 0 for a vehicle, the same
  degenerate answer an unresolvable map-event screen position already gets.
  Covered by a new `scripts/rpg2k_logic_check.rb` check (a boat and an
  airship's map id/x/y/facing read correctly from an interpreter on an
  unrelated map; an unplaced vehicle reads its (0,0) default), confirmed to
  fail against the pre-fix code before the fix.
