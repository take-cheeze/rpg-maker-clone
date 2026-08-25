- **CI: a new `psp-smoke-game` job boots a real RPG2k game (Nepheshel) through
  the PSP EBOOT under PPSSPP-headless.** `psp-smoke` only ever exercises the
  idle HAL screen (no project at `app/psp/main.cxx`'s fixed `kGameDir`), so
  `RPG2K_PSP_GAME_READY` never fired and `RPG2K_PSP_BRINGUP`'s `scene=` was
  always `none` — the real device memory numbers
  `docs/adr/0047-psp-memory-budget.md`'s P1/P1b need ("memory right before
  the title screen", steady-state `RPG2k::Scene::Title`) had no CI run that
  could produce them. The new job places Nepheshel (the same RPG2000
  test-bed the desktop `build` job already downloads) at the EBOOT's fixed
  Memory Stick path (headless's own default memstick root, `$HOME/.ppsspp`,
  written ahead of the emulator's own first-run setup — a `--memstick=DIR`
  flag looked right from PPSSPP's source but the first real CI run showed
  its arg parser never consuming it as a flag at all) and asserts boot,
  game detection and the frame loop the same way `psp-smoke` does. Marked
  `continue-on-error: true` for now, the same starting point `psp-smoke`
  itself used before its own HLE gaps were fixed — this is the first CI run
  to boot a real game on this target, and Nepheshel's download host has its
  own known intermittency unrelated to the EBOOT.
