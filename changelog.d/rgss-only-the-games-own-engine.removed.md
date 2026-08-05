- **RPG Maker XP runs only the game's own engine now.** The reimplemented
  title/map/event flow — `mruby-rpgxp`'s `game.rb`, `scene.rb` and
  `interpreter.rb`, about 4,600 lines — has been removed, along with
  `--rpgxp_new_game`, whose only job was driving its title screen. A project's own
  `Data/Scripts.rxdata` is what runs; a project that ships none reports that
  instead of being played by a stand-in, and a failure inside a game's scripts
  ends the run with the section and line it came from rather than quietly landing
  the player in a different engine that looks like the game.

  A reimplementation can only ever reproduce the *default* scripts, and every
  game worth running replaces some of them. Keeping it also meant learning each
  RGSS behaviour twice — once for the class library a game's scripts call, once
  for the stand-in — with no way to see the two drift. See ADR 0030.

  The checks moved with it: `scripts/rpgxp_boot_check.bash` taps confirm on each
  game's own title screen, asserts it reaches a second scene and walks the party
  on the editor bed's map (`--rgss_host_move_test`, `[RPGXP-HOST-MOVE]`);
  `scripts/rgssad_asset_check.bash` keeps its packed-with/without-the-title-graphic
  A/B, now through the game's own `Scene_Title` and `RPG::Cache`; and
  `scripts/compare-rpgxp-wine.bash` now diffs the game's own engine against the
  genuine runtime, which is what a render comparison should measure. The RPG
  Maker 2000/2003 runtime is untouched — LCF games ship no scripts, so a
  reimplementation is the only thing that can run them.
