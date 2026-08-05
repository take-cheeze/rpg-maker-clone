- **A picture's tone is drawn.** Show / Move Picture carry four RPG2000 tone
  channels (red / green / blue / saturation, 0..200 with 100 neutral); they were
  parsed, moved and saved, but never reached the screen, so a picture asked for
  at 30 % brightness rendered at full. `Scene::Map` now tones the source through
  the native `Bitmap#tone_blt` before compositing it, caching the result per
  image + tone so the software pass runs when the tint changes rather than every
  frame, and skipping it altogether for a neutral picture. The channel
  conversion truncates toward zero to match the reference's C++ integer
  arithmetic rather than Ruby's flooring, and RPG2000's saturation — which
  counts *down* from 100 to mean less saturated — is inverted into RGSS's grey,
  which counts up. Measured on the RPG2003 test-bed
  (`scripts/download-mtf-meido-action.bash`), which leans on pictures far harder
  than Nepheshel: **128 of its 315 Show Pictures and 17 of its 117 Move Pictures
  carry a non-default tone**, 95 of them the same heavy darkening and 10 fully
  black. This uses the path pictures already draw through — a blit into the
  shared picture bitmap — not the per-frame `Sprite#bitmap=` swap that the
  map-layer tint attempt found does not reach the display.
