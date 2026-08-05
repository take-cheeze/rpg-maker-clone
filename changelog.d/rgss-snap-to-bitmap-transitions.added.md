- **`RGSS::Graphics.snap_to_bitmap`, and real `freeze`/`transition` on top of
  it — scenes dissolve into each other.** Every RGSS scene change goes through
  `Scene_Base#perform_transition`: freeze the frame, build the next scene behind
  it, dissolve the still away. Both halves were `warn_stub` no-ops that only
  burned the right number of frames, and `snap_to_bitmap` (which `Scene_Title`
  calls outright) did not exist at all.
  - `snap_to_bitmap` is native: `lv_snapshot_take` re-renders the active screen's
    object tree into an ARGB8888 buffer. That is the only capture that works on
    every backend here — the SDL window, the terminal framebuffer and the wasm
    canvas all buffer differently, and two of them render partially — and the
    rows come back in the byte order `Bitmap` already uses, so they copy across
    directly. The two bare-metal targets (Wio, PSP) keep `LV_USE_SNAPSHOT` off
    and answer `nil`, saying so once rather than pretending.
  - `freeze` keeps the snapshot; `transition` puts it on a full-screen sprite
    above everything and steps its opacity to zero over `duration` frames, which
    is RGSS's default dissolve. The `filename`/`vague` form (dissolving *through*
    a transition image) still runs as a plain fade of the same length and says so
    once.
  Shared by the XP and VX/VX Ace script hosts, since both use the same
  `mruby-rgss`.

- **A render probe that can actually see the screen (`render_probe` ctest).**
  `Viewport#color`, `Viewport#tone` and now the transitions are native rendering
  that `mruby-rgss/test` cannot reach: that binary has no display, so a
  `Viewport` cannot even be constructed there. The failure mode that leaves is
  the dangerous one — the code runs, the values are stored, and the screen never
  changes, which is exactly how an earlier RPG2000 screen tint shipped broken
  (`docs/TODO.md`).
  `RGSS.frame_mean` returns the frame's mean R/G/B (sampled on an 8px grid
  through `snap_to_bitmap`), and `RGSS.effect_probe` drives a grey screen, a red
  `Viewport#color`, an additive-blue `Viewport#tone` and a freeze/transition
  round trip on a real display, measuring each against the last —
  `base=[128,128,128] color=[191,63,63] tone=[128,128,255] cleared=[0,0,0]
  mid=[94,94,94] after=[0,0,0]`. `rpg_maker_clone --rgss_effect_probe` runs it
  and reports through the exit code; it needs no game directory, and CI runs it
  as the `render_probe` ctest under xvfb (reserved display 98). The assertions
  were confirmed non-vacuous by neutering `vp_refresh_overlay` and the transition
  in turn — each broke exactly the check it should and nothing else.
