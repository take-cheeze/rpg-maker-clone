- MZ (M6.3c, in progress): the WebGL wrapper now exposes the GL enum constants as
  static properties on the global `WebGLRenderingContext` constructor
  (`WebGLRenderingContext.RGBA`, `.SCISSOR_TEST`, ...), not only on the context
  instance. PIXI v5's ScissorSystem/StencilSystem read the enums off the
  constructor while building the renderer, so `new PIXI.Renderer` threw a
  ReferenceError without them. Found by booting PIXI v5.2.4 (the version RPG
  Maker MZ ships) against the wrapper's method surface under Node; with this,
  PIXI constructs its renderer and renders a sprite through the wrapper.
