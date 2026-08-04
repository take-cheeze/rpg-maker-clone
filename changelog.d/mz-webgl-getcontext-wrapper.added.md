- MZ (M6.3b): the WebGL method wrapper — `mruby-mvjs/src/mvwebgl.cxx` maps the
  `WebGLRenderingContext` surface PIXI v5 drives onto the native surfaceless-EGL
  GLES2 backend (M6.3a), so `canvas.getContext("webgl")` (and the
  `"experimental-webgl"` alias) returns a real, native-backed context instead of
  `null` and `Utils.canUseWebGL()` becomes true — the gate `SceneManager.run`
  hits before rendering. It follows the Canvas2D bridge's idiom (opaque integer
  handles + flat `__mv_gl*` C functions + a JS prototype); WebGL API objects are
  represented by their GL integer names, and `bindFramebuffer(_, null)` targets
  the context's own FBO since a surfaceless context has no default framebuffer.
  `gl_test.rb` drives a green triangle end to end through the wrapper (compile
  ES 1.00 shaders → buffer → draw → `readPixels`). Where the EGL backend is
  absent (Emscripten's browser WebGL, or a header-less build) the natives are
  not installed and `getContext("webgl")` stays `null`, so PIXI keeps its Canvas
  path. The PIXI-specific long tail (getExtension/VAO, texture Y-flip and image
  uploads, on-screen present) is M6.3c.
