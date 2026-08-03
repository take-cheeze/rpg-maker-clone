- MV canvas gradient fills: `Bitmap.gradientFillRect` now renders. The
  Canvas2D bridge's `createLinearGradient`/`createRadialGradient` return real
  objects that record their axis and colour stops, and a gradient `fillStyle`
  is rasterised per-pixel (projecting each pixel onto the transform-mapped
  gradient axis and interpolating the stops) instead of falling back to opaque
  black — so HP/MP/TP gauges and window dimmer backgrounds draw with their
  intended ramps. Radial gradients approximate as a linear ramp for now.
  Covered by `mruby-mvjs/test/canvas_test.rb`.
