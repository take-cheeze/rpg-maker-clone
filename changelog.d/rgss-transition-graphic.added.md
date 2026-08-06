- **`Graphics.transition` dissolves through a transition graphic.** Given a
  `filename`, the frozen still now gives way in the *shape* of that image
  instead of fading flat: its brightness says when each pixel goes — dark first,
  light last — and `vague` how soft the boundary between the two is. That is what
  makes RPG Maker XP's default battle transition a pentagram rather than a fade,
  and it is the form a released game reaches for. The shader-based players
  evaluate `clamp((t - prog) / vague, 0, 1)` on the GPU; there is none here, so
  `RGSS::Bitmap#_transition_alpha` rewrites the snapshot's alpha channel once per
  frame. A graphic that will not load falls back to the plain fade and says so
  once.
- **`RGSS.effect_probe` measures the shape, not just the change.** A dissolve
  that ignored its map would still change the frame, only uniformly — so the
  probe half-dissolves a solid still through a left-to-right gradient and means
  each edge of the screen separately, requiring the dark side to be gone while
  the light side still stands. `RGSS.frame_mean` takes an optional region for
  it.
