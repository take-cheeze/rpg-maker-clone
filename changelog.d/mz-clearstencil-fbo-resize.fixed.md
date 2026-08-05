- MZ: the game no longer stalls on the title screen. `WindowLayer.render` calls
  `gl.clearStencil` on every frame that draws a window, and the WebGL wrapper did
  not implement it — the resulting `TypeError: not a function` is fatal rather
  than transient, because PIXI v5 re-arms its `requestAnimationFrame` only after
  `update()` returns, so one throw inside the ticker stops the game loop for
  good. Added beside the existing stencil stubs, together with `polygonOffset`
  and the `uniform3i`/`uniform4i` setters PIXI generates for `ivec3`/`ivec4`
  uniforms.
- MZ: the WebGL render target now follows the canvas. The context is taken from a
  canvas that is still 0x0 (clamped to a 1x1 target) and MZ sizes it only later,
  in `Scene_Boot.resizeScreen` → `Graphics.resize` → PIXI's `renderer.resize`;
  nothing followed that, so the whole game rendered into a single pixel and both
  the on-screen present and `--mz_screenshot` read one pixel back. `mvgl::resize`
  re-specifies the colour and depth/stencil renderbuffers, `__mv_glResize`
  exposes it, and the canvas' width/height setters drive it. Covered by a
  `gl_test` case in the order that matters — context first, size second — which
  the existing tests happened to avoid.
