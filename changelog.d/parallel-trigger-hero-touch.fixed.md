- **A map event page set to Parallel Process now also answers hero contact**,
  on top of the background loop it already runs continuously. `touch_trigger?`
  (`mruby-rpg2k/mrblib/scene/map.rb`) only recognised Player Touch (1) and
  Event Touch (2), so a Parallel-triggered (4) event never started through the
  foreground touch path at all — matching yado.tk's documented quirk, it now
  fires instantly on overlap for a below/above-characters page and repeatedly
  while a direction key is held into a same-as-characters (blocking) one,
  through a second, independent run of the shared foreground `@interpreter`
  that leaves the event's own always-running background process untouched.
  Covered by a new `scripts/rpg2k_scene_check.rb` check, confirmed to fail
  against the pre-fix code before the fix.
