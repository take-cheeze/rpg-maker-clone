- MV canvas `putImageData`: the Canvas2D bridge now writes pixels back to a
  canvas instead of ignoring the call. MV's `Bitmap.adjustTone` and
  `Bitmap.rotateHue` read pixels with `getImageData`, recolour them and commit
  them via `putImageData`; that write-back was a no-op, so hue-shifted graphics
  (recoloured enemies/animations) and tone adjustments silently kept their
  original colours. The new native (`__mv_canvasPutData` in
  `mruby-mvjs/src/mvcanvas.cxx`) copies the pixels straight in — no source-over
  blend, no transform, clamped to 0-255 to match a real `ImageData`'s
  `Uint8ClampedArray`. Unit-tested in `mruby-mvjs/test/canvas_test.rb`.
