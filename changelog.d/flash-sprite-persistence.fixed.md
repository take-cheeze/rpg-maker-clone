- **The hero's own in-flight Flash Sprite (or a map-triggered battle-
  animation pulse targeting the hero) now survives Save/Continue.**
  Previously tracked only as `Scene::Map`'s own transient `@player_flash`
  instance variable, invisible to both save formats — a save taken mid-flash
  and continued silently dropped it instead of resuming the fade. Promoted
  onto `Game::State#player_flash`, round-tripped through both the portable
  Marshal save (`#to_h`/`#load_h`) and a genuine `.lsd` (`#to_lsd`/`.from_lsd`,
  chunk 104's own `flash_red`/`_green`/`_blue`/`_current_level`/`_time_left`,
  liblcf's generator/csv/fields.csv fields 0x51-0x55/81-85). Confirmed
  against a genuine kk1.12 save under wine for the *not flashing* case: the
  RGB triple is present as an explicit 0 (not the schema's own -1 generator
  default, and not absent), while the current-level/time-left pair stays
  absent. The *flashing* case's own exact decay curve (whether
  `flash_current_level`'s interpolation matches this codebase's own linear
  one) has not been independently confirmed against genuine RPG_RT — a save
  resumed mid-flash restarts its own decay from the already-decayed current
  level, one frame short of exactly reproducing the original fade.
