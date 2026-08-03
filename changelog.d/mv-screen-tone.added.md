- MV negative screen tones (map darkening): the Canvas2D bridge now implements
  `globalCompositeOperation = 'difference'`. MV's `ToneSprite` (the Canvas-path
  screen-tone changer, used because we run PIXI's canvas renderer) darkens the
  frame with a difference/lighter/difference fill sequence, gated on the boot
  probe `Graphics.canUseDifferenceBlend()`. That probe reads a white-on-white
  `difference` pixel and only enabled the path if it came back black — which it
  never did while the op fell through to source-over, so negative tones (night,
  caves, dungeons, "Tint Screen" event commands) had no effect. With the real
  op, the probe passes and negative tones darken the map. Positive tones already
  worked via `'lighter'`; `'saturation'` (grey/desaturation) stays disabled.
  Unit-tested in `mruby-mvjs/test/canvas_test.rb`.
