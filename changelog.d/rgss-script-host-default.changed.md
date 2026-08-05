- **The RGSS script host is now the default boot path.** An RPG Maker XP / VX /
  VX Ace project that ships `Data/Scripts.rxdata` / `Scripts.rvdata[2]` runs its
  own bundled Ruby — title, menus, battle system and any community scripts — the
  way `RGSS104E.dll` runs it, instead of the reimplemented title/map flow. What
  had kept it behind a flag is done: the `mruby-rgss` class library the stock
  scripts call renders, `Kernel#sprintf`/`exit` are in the build, and the
  scripts' blocking main loop is driven one frame per callback by the Fiber
  driver (ADR 0023). `RGSS_SCRIPT_HOST` flips from an opt-in to an **opt-out**,
  and now really reaches the engine: the native runtime resolves it (and the new
  `--rgss_script_host` flag it seeds) and passes the answer to Ruby as a
  constant, since this mruby build has no `ENV`. `--rpgxp_new_game` implies the
  built-in flow too, being the flag that drives its title screen. The built-in
  flow stays as the fallback for a project that ships no scripts and for a host
  that fails to boot. `ScriptHost.run` logs
  `[RPGXP-SCRIPTS] running N script sections`, and
  `scripts/rpgxp_boot_check.bash` now boots each XP bed twice in CI — under the
  host (failing if it fell back) and through the built-in flow into the map. See
  ADR 0029.
