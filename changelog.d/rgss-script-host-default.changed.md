- **The RGSS script host is now the default boot path.** An RPG Maker XP / VX /
  VX Ace project that ships `Data/Scripts.rxdata` / `Scripts.rvdata[2]` runs its
  own bundled Ruby — title, menus, battle system and any community scripts — the
  way `RGSS104E.dll` runs it, instead of the reimplemented title/map flow. The
  switch (`--rgss_script_host`, and the `RGSS_SCRIPT_HOST` environment variable
  that seeds it) flips from an opt-in to an **opt-out**: `--norgss_script_host`
  boots the built-in flow, which also stays as the automatic fallback for a
  project that ships no scripts and for a host that fails to boot.
  `--rpgxp_new_game` implies it too, being the flag that drives the built-in
  title screen. `ScriptHost.run` logs `[RPGXP-SCRIPTS] running N script
  sections`, and `scripts/rpgxp_boot_check.bash` now boots each XP bed twice in
  CI — under the host (failing if it fell back) and through the built-in flow
  into the map. See ADR 0029.
- **The RGSS standard library a game is written against now exists**
  (`mruby-rpgxp/mrblib/rgss_library.rb`): `RPG::Sprite`, `RPG::Weather` and
  `RPG::Cache` are Ruby classes the *player* supplies, so no project ships them
  — and without them a game stopped 21 sections into its own engine on
  `class Sprite_Character < RPG::Sprite`. `RPG::Sprite` brings the battler
  transitions (whiten / appear / escape / collapse), the floating damage pop-up
  (white, green for recovery, `CRITICAL` above a critical hit), blinking, and
  `RPG::Animation` playback over a sprite — 16 cell sprites aimed from each
  frame's cell data, with the frame timings' sound effect and flash, following
  the sprite as it moves; `RPG::Weather` brings rain, storm and snow;
  `RPG::Cache` the bitmap cache every graphic a game loads goes through,
  including cutting a tile out of a tileset and hue-rotated variants. Transcribed
  from the definitions published in the RGSS Reference Manual, with three
  deviations this engine forces (listed in the file's header). A missing asset
  now yields a blank bitmap and a warning where RGSS raises, so a game whose RTP
  is not installed still boots.
- `scripts/rpgxp_script_host_check.rb` **stops stubbing our own Ruby**: it loads
  the real `rgss_library.rb`, evaluates *every* section of a real bundle except
  `Main` (it used to evaluate a hand-picked subset), and drives the sprite
  effects, animation, weather and cache against fakes for the native classes
  only. The empty `RPG::Sprite` stub it used to define is why the check stayed
  green while no XP game could boot.
