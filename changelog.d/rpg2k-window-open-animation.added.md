- **rpg2k windows unroll open and shut instead of popping.** Ported from
  EasyRPG Player's `Window::SetOpenAnimation`/`SetCloseAnimation`
  (`src/window.cpp`): the window's frame grows from its horizontal centre line
  over a handful of frames, and contents/cursor/the pause arrow stay hidden
  until it is fully open — the same behaviour `RGSS::Window`'s native
  `openness` already draws for XP/VX windows (`mruby-rgss/src/lib.cxx`),
  reimplemented in pure Ruby for `RPG2k::Window` since it is not a native
  class. Wired into the two places RPG_RT actually animates: the **title
  screen's command window** (8 frames, skipped under HideTitle) and the
  **message window** and its `\$` gold window (7 frames, instant during
  battle — EasyRPG's `constexpr int message_animation_frames = 7`, gated on
  `Game_Battle::IsBattleRunning()`). Closing is decoupled from dismissal the
  way EasyRPG's `Window_Message` decouples it from
  `FinishMessageProcessing()`: the window is handed off to
  `Scene::Map#update_closing_windows` and keeps shrinking in the background
  while the interpreter and the rest of the scene carry on immediately, rather
  than blocking on the animation. Every other rpg2k window (menu, item, equip,
  skill, status, shop, inn, ...) is untouched — EasyRPG's own source has no
  `SetOpenAnimation` call for any of them either.
