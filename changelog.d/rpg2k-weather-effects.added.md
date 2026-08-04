- The **Weather Effects** (11070) event command is now handled: it records the
  map weather type (param0 — 0 none, 1 rain, 2 snow, higher values for the
  RPG2003 additions) and strength (param1 — 0 weak .. 2 strong) on a new
  `Game::Weather` model held by `Game::State`. Non-blocking, and the setting
  round-trips through Save / Continue (defaulting to none on a save written
  before it existed). Like the picture and screen-tint overlays this is the
  Ruby-half model only — compositing the rain/snow particles is native (C++)
  renderer work still to come. Covered by new checks in
  `scripts/rpg2k_logic_check.rb`.
