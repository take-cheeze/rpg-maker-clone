- **The PSP EBOOT now builds `MinSizeRel` instead of `Debug`.** The pin was
  `Debug` because `-O2` halted on LVGL's TLSF assert, and the comment said it
  was provisional pending a root cause. That cause turned out not to be
  optimisation at all — it was `psp-fixup-imports` leaving tail-call `j`
  instructions pointing at pre-reorder import stubs, and optimisation merely
  emits more tail calls, so it hit more of them. With that fixed, `Debug`,
  `RelWithDebInfo` and `MinSizeRel` all reach `RPG2K_PSP_GAME_START` and hold a
  `RPG2K_PSP_BRINGUP` heartbeat with identical memory telemetry. `-Os` is the
  right default here because the whole EBOOT is loaded into the console's
  ~24 MB at launch, so every byte of `.text` is live RAM: 2,095,840 bytes
  against `Debug`'s 2,477,972 and `-O2`'s 2,217,032 — 373 KB back.
