- **Fixed: `#disposed?` answered the opposite of the truth on every RGSS display
  object.** `Bitmap`, `Sprite`, `Viewport`, `Plane`, `Tilemap` and `Window` all
  share one native `disposed?`, and it returned whether the object was *alive* —
  so a fresh bitmap reported itself disposed and a freed one reported itself
  fine. RGSS scripts guard cleanup and redraws with exactly this
  (`unless bitmap.disposed?`, `return if @sprite.disposed?`), so inverted it
  means skipping work on a live object and reaching into a freed one.

  Nothing in the engine read the value, which is why it survived: the tests only
  asserted the method *existed*. There is now one that checks what it answers,
  on `Bitmap` — the one display class that needs no display, so the behaviour can
  be pinned headlessly.
