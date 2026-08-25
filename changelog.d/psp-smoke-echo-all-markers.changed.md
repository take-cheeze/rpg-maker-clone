- **CI: the `psp-smoke` job now echoes every `RPG2K_PSP_*` marker, not just
  `BOOT`/`BRINGUP`.** The new `RPG2K_PSP_PRE_MRUBY_OPEN`/`RPG2K_PSP_MRUBY_OPEN`
  (`mrb_open()`'s own memory/timing cost) and `GAME_START`/`GAME_READY`/
  `GAME_STOP` markers were already written to `headless.log`, but the job's
  own printed output only ever grepped `BOOT`/`BRINGUP` — seeing the others
  meant pulling the full `psp-smoke` artifact, which needs direct GitHub API/
  blob-storage access the job log itself does not. `.github/workflows/build.yml`
  now greps `RPG2K_PSP_[A-Z_]+` (still gated on `BOOT`/`BRINGUP` both being
  present, unchanged). See `docs/adr/0047-psp-memory-budget.md`.
