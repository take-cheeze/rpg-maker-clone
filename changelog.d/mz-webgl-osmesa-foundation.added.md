- MZ (M6.3a): laid the WebGL renderer's foundation — an OSMesa (off-screen
  software Mesa) GLES2 context that renders into a CPU RGBA buffer, matching the
  software LVGL pipeline with no GPU or display (works headless in CI). Lives in
  `mruby-mvjs/src/mvgl.cxx`, exposed to Ruby as `MV::GL`; `MV::GL.smoke_test`
  compiles the PIXI-style GLSL ES 1.00 shaders, draws and reads a pixel back, and
  is pinned by `mruby-mvjs/test/gl_test.rb`. GLES2 is the target because PIXI
  v5's WebGL1 shaders are GLSL ES 1.00, which Mesa compiles verbatim, so no
  shader-translation layer is needed. The backend is build-optional: `mvgl.cxx`
  stubs itself out (an `__has_include` guard) and `MV::GL.available?` reports
  false where the OSMesa headers are absent, so the CMake link and the gem test
  only pick it up where the libraries exist. It is verified on the apt-based dev
  build; nixpkgs 26.05 no longer ships `libOSMesa` as a plain package, so the
  nix/CI build stubs it and the smoke test skips there for now (packaging OSMesa
  for nix is a follow-up). The Emscripten build (browser WebGL) also stubs it.
  The WebGL method surface and `getContext("webgl")` wiring follow in M6.3b/c.
