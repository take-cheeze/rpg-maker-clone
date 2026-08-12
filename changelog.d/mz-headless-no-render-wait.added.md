- `RGSS::Graphics.update` paces every frame against wall-clock 60fps (a
  `lv_delay_ms` sleep at the end of each frame — see docs/adr/0021), which
  matters for a played game but only padded a headless smoke test: the MZ boot
  checks (`scripts/mz_boot_check.bash`) drive hundreds of frames through
  software-GL rendering just to watch a probe complete, and every one of those
  frames was still throttled to real-play speed even though nothing was
  watching. A new `--no_render_wait` flag skips that sleep — `TIMEOUT_MS`/
  `TEST_PLAY`-style, read once per frame from a `NO_RENDER_WAIT` constant the
  native runtime sets — and is test-play-only tooling like the rest of that
  block. Game logic is timed off `Graphics.frame_count`, not the wall clock, so
  the frames that run are unaffected: measured against `data/mz-sample`, the
  `play`, `menu` and `save` boot-check modes ran 25-50% faster
  (e.g. `menu`: 19.5s -> 9.3s) with byte-identical captured frames; the
  CPU-bound play-out modes (`battle_play`, whose own per-frame rendering
  already exceeds a 60fps budget under software GL) saw no change, as
  expected. `scripts/mz_boot_check.bash` now passes it on every run.
