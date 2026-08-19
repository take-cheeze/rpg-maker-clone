- **MV** `CanvasRenderingContext2D.getImageData` now returns a real
  `Uint8ClampedArray` (matching the Canvas2D spec) instead of a plain Array.
  Third-party code that calls typed-array-only methods on `ImageData.data` —
  notably PIXI's own `extract.canvas`, which `Bitmap.snap`/`snapToBitmap`
  routes scene-transition snapshots through — threw `TypeError: not a
  function` on `data.set(...)`, crashing the game the first time it tried to
  transition scenes. Found booting a real downloaded MV game (Lunatic-Core)
  into New Game, where it broke every probe past the title screen.
