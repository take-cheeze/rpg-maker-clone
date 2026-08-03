- MV grey / desaturation tones: the Canvas2D bridge now implements
  `globalCompositeOperation = 'saturation'`, completing screen-tone support
  alongside `'lighter'` (positive) and `'difference'` (negative). MV's
  `ToneSprite` and per-sprite tinting desaturate by filling white in
  `'saturation'` mode, gated on the boot probe `Graphics.canUseSaturationBlend()`
  — which stayed false while the op fell through to source-over, so the grey
  component of a screen tone (flashbacks, sepia/monochrome scenes) had no
  effect. MV only ever fills white here, so the blend collapses each pixel to
  its own luminosity (a brightness-preserving greyscale) by the fill's coverage;
  the probe now passes. Implemented as blend mode 3 in
  `mruby-mvjs/src/mvcanvas.cxx` and unit-tested in
  `mruby-mvjs/test/canvas_test.rb`.
