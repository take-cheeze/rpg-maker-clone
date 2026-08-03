- MV additive blend mode: the Canvas2D bridge now honours
  `ctx.globalCompositeOperation = 'lighter'` (PIXI's ADD blend) on `fillRect`
  and `drawImage`, adding the source into the destination and clamping instead
  of always compositing source-over. MV drives this for battle-animation
  flashes, weather and glow sprites, which previously rendered too dark. The
  native blend (`mruby-mvjs/src/mvcanvas.cxx`) gained an additive path selected
  by a composite-op mode threaded through from the context; the mapping is
  unit-tested (`mruby-mvjs/test/canvas_test.rb`).
