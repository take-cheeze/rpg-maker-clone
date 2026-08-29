- **rpg2k windows unroll open and shut instead of popping.** Ported from a
  reference implementation, not independently confirmed against genuine
  RPG_RT under wine: the window's frame grows from its horizontal centre line
  over a handful of frames, and contents/cursor/the pause arrow stay hidden
  until it is fully open — the same behaviour `RGSS::Window`'s native
  `openness` already draws for XP/VX windows (`mruby-rgss/src/lib.cxx`),
  reimplemented in pure Ruby for `RPG2k::Window` since it is not a native
  class. Wired into the two places RPG_RT actually animates: the **title
  screen's command window** (8 frames, skipped under HideTitle) and the
  **message window** and its `\$` gold window (7 frames, instant during
  battle — 7 frames, a constant carried over from that reference
  implementation, gated on whether battle is running). Closing is decoupled
  from dismissal the same way that reference implementation decouples it
  from finishing message processing: the window is handed off to
  `Scene::Map#update_closing_windows` and keeps shrinking in the background
  while the interpreter and the rest of the scene carry on immediately, rather
  than blocking on the animation. Every other rpg2k window (menu, item, equip,
  skill, status, shop, inn, ...) is untouched — that reference
  implementation has no open-animation call for any of them either.
