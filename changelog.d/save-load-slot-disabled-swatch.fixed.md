- **Save/load screen:** every slot's text now renders through the
  windowskin's own system-colour swatches, matching real RPG_RT — it used
  to draw flat white regardless of the loaded windowskin, and an empty
  slot's file label never read as dimmed/disabled the way a genuine save
  screen's does. An occupied slot's label now uses the windowskin's default
  swatch (with its usual one-pixel drop-shadow); an empty slot's uses the
  disabled swatch, the same convention the title screen's Continue command
  already follows. Covered by a new `scripts/rpg2k_scene_check.rb` check.
