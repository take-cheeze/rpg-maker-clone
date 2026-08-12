- **Debugging and CI-automation tooling now requires test play.** A new
  `--test_play` flag (and, for RPG2000/2003, XP and VX/VX Ace projects, the
  project's own `Game.ini` `[Game] Test=1` — the same signal the RPG Maker
  editors' Test Play button writes) marks a run as a playtest. The profiler
  (`--profile`/`--profile_trace`), the terminal log console and stats overlay
  (`--term_console`/`--term_stats`), the `--rgss_effect_probe`/
  `--rgss_audio_probe`/`--error_dump_probe` self-probes, and every headless
  input-injection flag (`--rpg2k_new_game`, `--rpg2k_continue`,
  `--rgss_host_*`, `--mv_*`, `--mz_*`) now do nothing outside test play — a
  released game launched plainly ignores all of them, whatever is on its
  command line. CI passes `--test_play` explicitly wherever it relies on this
  tooling.
