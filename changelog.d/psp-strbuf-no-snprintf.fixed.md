- **PSP EBOOT: every marker/status string is now built without `snprintf`.**
  pspsdk's `sysclib_snprintf`/`sysclib_sprintf` PPSSPP-headless HLE stubs are
  only partially implemented, and calling into them left the emulator's own
  state corrupted enough to contribute to a host-side crash a few syscalls
  later (confirmed with `gdb` against a core dump: a null-pointer write
  inside PPSSPP's own `sceKernelCreateLwMutex`). `app/psp/main.cxx` now
  builds every status line (`RPG2K_PSP_MRUBY_OPEN`, `RPG2K_PSP_GAME_START`,
  `RPG2K_PSP_GAME_STOP`, the on-screen key echo, and the `RPG2K_PSP_BRINGUP`
  heartbeat) with a small libc-free `StrBuf` instead — the same reasoning the
  `RPG2K_PSP_BOOT` marker's compile-time string literal already used. Closes
  the one flakiness source this EBOOT controlled; PPSSPP-headless still has a
  separate, unrelated kernel-emulation bug (reproduces even with none of this
  file's own code run yet, so it predates `main()`) that the `psp-smoke` CI
  job's non-blocking status already accounts for.
