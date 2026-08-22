- Fixed a real gap in `mruby-rgss`: `Window#viewport=` (RGSS3/VX Ace,
  reassigning an existing window to a Viewport so it clips and scrolls with
  it) did not exist at all, raising `NoMethodError` the moment a script
  called it. Found because a real RPG Maker VX Ace game's `Scene_Battle`
  assigns all its battle windows (`Window_BattleStatus` among them) to a
  dedicated viewport, and crashed on the very first one. Reparents the
  window's canvas via LVGL's own `lv_obj_set_parent` -- the same mechanism
  Sprite/Plane/Tilemap already use at construction, just made reassignable
  after the fact -- so it clips and scrolls with the target viewport (or
  moves back to the screen for `nil`) exactly like those already do.
