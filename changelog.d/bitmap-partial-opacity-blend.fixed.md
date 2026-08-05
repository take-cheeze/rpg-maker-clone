- `Bitmap#blt` / `#stretch_blt` at partial opacity no longer darken what they
  draw. They blended the source colour toward the destination even when the
  destination was *transparent* — that is, toward black — while recording the
  reduced alpha, so the later composite attenuated the same colour a second
  time. Straight (non-premultiplied) source-over fixes it, and reduces to the
  old formula when the destination is opaque, so blits onto an opaque bitmap are
  unchanged (the RPG2000 title screen renders byte-for-byte as before). Measured
  against the genuine RGSS runtime: a window background drawn at `back_opacity` 160
  showed 8% of its windowskin where the real runtime shows 63% (= 160/255).
- RPG Maker XP windows honour `back_opacity`, and their selection cursor is
  drawn from the windowskin's own 32x32 cursor block (nine-sliced) rather than a
  flat blue bar. The title screen sets 160, as RMXP's `Scene_Title` does, so the
  title graphic shows through the menu the way it does in the real runtime: the
  window's pixels went from 95% differing to 52%, the rest being text the
  reference cannot draw (no font is installed in the wine prefix).
