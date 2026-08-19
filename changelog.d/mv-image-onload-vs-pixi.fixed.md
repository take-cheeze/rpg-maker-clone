- **MV** the player never actually moved in *any* MV game — `Scene_Map`
  never became active because the tileset `Bitmap` got permanently stuck at
  `_loadingState: 'requesting'`. Root cause: the `Image` shim aliased
  `addEventListener('load'/'error', ...)` to the single `onload`/`onerror`
  property. `Bitmap#_requestImage` attaches its own completion handler that
  way, but PIXI's `BaseTexture` *also* assigns `image.onload` directly (to
  learn when an in-flight image finishes) — on real browsers these are
  independent listener slots that both fire, but our shim let PIXI's later
  assignment silently discard MV's own handler, so `Bitmap` never left
  `'requesting'` and `ImageManager.isReady()` never returned true. `Image`
  now keeps `addEventListener`-registered listeners and the `onload`/
  `onerror` properties independent, firing both, like a real `Image`
  element. Found by tracing why `[MV-MOVE] ... moved=false` on every probe,
  against both the authored `data/mv-sample` bed and a real downloaded game
  (Lunatic-Core).
- **MV** `Image#src` reassignment now invalidates any still-pending
  completion from a previous assignment on the same instance, matching a
  real browser's abort-on-reassign behavior. MV pools and reuses `Image`
  objects (`Bitmap._reuseImages`); without this, a stale queued completion
  from a since-discarded request could land on a reused instance after a new
  owner had already re-armed it.
