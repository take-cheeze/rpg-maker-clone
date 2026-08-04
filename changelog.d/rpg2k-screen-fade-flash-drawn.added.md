- **Erase / Show Screen and Flash Screen now actually draw.** Both were modelled
  in `Game::Screen` but nothing rendered them, so a game that faded to black
  simply kept playing in full view. `Scene::Map` now carries two screen-sized
  colour sprites above everything — the message window included, which is what
  RPG2000 does — shown at the effect's own 0..255 strength.

  These were recorded as blocked on native `RGSS::Viewport` tone/alpha support.
  They were not: `RGSS::Sprite#opacity` is already LVGL's per-object alpha at
  blit time, so no C++ change was needed. Verified in the real binary first —
  forcing the fade layer to opacity 128 halves the rendered frame's mean
  brightness. The **tint** does still need native work, since a tone multiplies
  against what is already drawn and cannot be reproduced by compositing a solid
  colour over it.
