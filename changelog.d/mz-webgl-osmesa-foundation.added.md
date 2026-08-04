- MZ (M6.3a): laid the WebGL renderer's foundation — an OSMesa (off-screen
  software Mesa) GLES2 context that renders into a CPU RGBA buffer, matching the
  software LVGL pipeline with no GPU or display (works headless in CI). Lives in
  `mruby-mvjs/src/mvgl.cxx`, exposed to Ruby as `MV::GL`; `MV::GL.smoke_test`
  compiles the PIXI-style GLSL ES 1.00 shaders, draws and reads a pixel back, and
  is pinned by `mruby-mvjs/test/gl_test.rb` — the CI-verifiable proof that the
  backend works without the proprietary MZ engine. GLES2 is the target because
  PIXI v5's WebGL1 shaders are GLSL ES 1.00, which Mesa compiles verbatim, so no
  shader-translation layer is needed. OSMesa/GLES2 are wired into the CMake link
  and `flake.nix`; the Emscripten build (browser WebGL) stubs them out. The
  WebGL method surface and `getContext("webgl")` wiring follow in M6.3b/c.
