- **`psp-smoke-game` CI now reaches `RPG2k::Scene::Map`, not just Title.**
  `app/psp/main.cxx` checks for a `.psp_ci_new_game` marker file next to the
  project's own data at `kGameDir` and, only when present, sets
  `RPG2K_NEW_GAME` true instead of its usual hardcoded false -- the same
  mechanism `src/main.cxx`'s desktop-only `--rpg2k_new_game` flag already
  drives, now reachable on the PSP target with no command line. A real
  release's own game folder never carries the marker (nothing in the editor
  or this codebase's packaging writes it), so every real player still lands
  on an ordinary title screen; only the `psp-smoke-game` CI job creates it,
  so `docs/adr/0047-psp-memory-budget.md`'s per-scene memory numbers can
  cover a loaded map and party, not just the idle title screen. See the
  ADR for the measured figures once this job has run.
