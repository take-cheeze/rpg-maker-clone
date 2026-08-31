- **Fixed:** every field-menu screen's selection cursor now actually
  blinks — Item, Skill, Equip, Save/Load and Order never called
  `Window#update` on any window they own, the same gap the field menu's
  own status panel had (see `menu-status-panel-face-cursor.fixed.md`).
  `Scene::Title` already did this correctly for its one window;
  `RPG2k::Window#update` is what advances `@cursor_frame` and redraws the
  blink, so without it every one of these screens' highlight boxes sat
  frozen on their first frame.
