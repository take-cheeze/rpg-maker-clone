- **The game timer now draws as five raw digit-sprite cells cut from the
  System graphic, matching RPG_RT's actual rendering, instead of a bordered
  window with `draw_text`'d `M:SS`.** Verified against EasyRPG Player's
  actual C++ source: `Sprite_Timer::Draw` (`src/sprite_timer.cpp`) blits five
  8x16 cells (minute tens, minute ones, a colon, second tens, second ones)
  straight out of the System graphic into a bare sprite with no window or
  border, and refuses to draw at all with no System graphic loaded — this
  codebase's old `Window`+`draw_text` timer kept showing its digits even
  with no windowskin, only losing the border decoration. Fixed with a new
  `build_timer_sprite`/`draw_timer_digits` pair on `Scene::Map`
  (`mruby-rpg2k/mrblib/scene/map.rb`), including the colon's real blink (off
  for the first half of every second, on for the second), the exact
  left/right screen-edge X positions RPG_RT parks the two timers at, and the
  battle-only Y drop to the mid-screen slot. The message-window-adjacent Y
  reposition (moving to the bottom edge when a sticky, persistent message
  window sits at the top) stays unmodelled, since this build has no
  persistent message-window object to read a position back from. Covered by
  six new `scripts/rpg2k_scene_check.rb` checks, confirmed to fail against
  the pre-fix code before the fix.
