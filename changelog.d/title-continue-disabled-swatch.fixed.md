- **Title screen:** a disabled Continue label now reads its color from the
  windowskin's own disabled-colour swatch (system colour index 3), matching
  every other grayed-out RPG_RT menu command — it used to draw a hardcoded
  flat gray regardless of the windowskin, so a custom skin with a tinted
  disabled swatch (rather than neutral gray) rendered Continue wrong, and
  it never got the shared one-pixel drop-shadow every other label gets. A
  game with no windowskin loaded still renders the same flat gray as
  before. Covered by a new `scripts/rpg2k_scene_check.rb` check.
