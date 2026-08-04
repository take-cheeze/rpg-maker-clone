- **RPG Maker XP — RGSS script host.** A project's bundled `Data/Scripts.rxdata`
  can now be run unmodified, the way `RGSS104E.dll` does: `RPGXP::ScriptHost`
  decompresses the ~90 Ruby sections (via a new native `RGSS.zlib_inflate` that
  reuses stb_image's zlib decoder), installs the Kernel `load_data`/`save_data`
  built-ins through the project database, and evaluates each section at the top
  level so the game's own engine — title, map, event interpreter, battle — drives
  itself. Requires the core `mruby-eval` gem. Opt-in for now
  (`RGSS_SCRIPT_HOST`), with the built-in reimplemented flow (ADR 0010) as the
  default and the fallback. Decoding, the built-ins and top-level evaluation of
  real script source are validated against the `OpenGame.exe` XP test bed by the
  new `scripts/rpgxp_script_host_check.rb` (run in CI). See ADR 0017.
