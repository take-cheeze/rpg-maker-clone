- Even with the frame-pacing wait gone (`--no_render_wait`), a headless MZ
  boot check was still spending most of its time on real work nobody looks
  at: profiling `data/mz-sample`'s `play` mode showed PIXI's actual WebGL
  render (software-rasterised on the surfaceless-EGL backend) at ~95% of the
  per-frame JS pump, while the game-logic half of the same tick
  (`SceneManager.updateMain`) cost almost nothing. Every `mz_boot_check.bash`
  mode captures exactly one screenshot and otherwise reads JS/Ruby state, not
  pixels, so a `--no_render_wait` run now wraps `Graphics._app.render` (once
  `SceneManager.run` has built it) and suppresses it on every frame but the
  one `#maybe_screenshot` is about to capture, forcing one real render right
  before that read so the frame it gets is exactly what an unskipped run
  would have shown. Scene transitions, fades and animation counters are
  unaffected — they live entirely in the update half of the tick, never the
  render — so the game state at capture time does not change, only the
  wasted renders leading up to it. Measured against `data/mz-sample`: `play`
  dropped from ~6.2s to ~2.1s with a byte-identical captured frame, and all
  14 `mz_boot_check.bash` modes plus the cross-mode `mz_frame_check.rb`
  sweep (54 checks, including the delicate animation-burst and
  encounter-battle content checks) still pass.
