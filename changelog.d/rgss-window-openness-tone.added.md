- **VX windows unroll instead of popping, and `Window#tone` tints them.** The
  last two behavioural gaps in the RGSS2/RGSS3 window (`docs/rpgvx-rgss-api-gap.md`
  item 4). Both were stored-but-never-drawn: the value went in, the screen never
  changed, and because the stock scripts only ever wait on the value they set
  (`Window_Base#open` steps `openness` by 48 a frame and polls `open?`), a game
  looked correct while every menu appeared instantly.
  - **`openness`** now draws. The window unrolls from its horizontal centre
    line: the frame is composited at `height * openness / 255` and the object
    shifted down by half of what it lost, so it grows out of the middle the way
    RGSS does. The 9-slice's corner height is clamped to half the drawn height,
    so a part-open window keeps a frame rather than laying its top and bottom
    borders over each other. Contents, cursor and pause arrow are hidden until it
    is fully open — only the frame animates.
  - **`Window#tone`** now draws, over the *background* only: applied to the
    canvas right after the background tile and before the frame and contents go
    on top, which confines it without a second buffer. Unlike `Viewport#tone` it
    is not folded in by children — a window composites itself — but the
    per-pixel maths is the same shared `apply_tone_px`, so the three tone paths
    cannot drift apart. `Window#update` re-checks it, since the scripts mutate
    the Tone in place (`window.tone.set(...)`); one comparison a frame when it
    has not moved.
  - Both are native and deliberately **not** redefined in mrblib. That loads
    after the C init, so a Ruby accessor there shadows the native one and
    silently goes back to storing a value that draws nothing — the trap that
    `Viewport#tone` already had to be rescued from once.

  Measured by `RGSS.window_probe` in the `render_probe` ctest, using area: a
  320×240 solid-blue window on a 544×416 screen, so the frame's mean blue is the
  fraction of the screen it covers — `drawn=[0,0,86] half=[0,0,43]
  closed=[0,0,0] toned=[86,0,86]`. 43 is half of 86, and 86 is
  255 × 320×240 / (544×416). Confirmed non-vacuous by breaking each half in
  turn: drawing at full height regardless of openness fails the half and closed
  checks, and skipping the tone pass fails only the tone check.
