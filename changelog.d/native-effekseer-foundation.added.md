- Vendored the real Effekseer C++ SDK (`3rd/effekseer`, MIT, pinned to
  release tag `1807`) and wired it into the build (`CMakeLists.txt`,
  `mruby-mvjs/mrbgem.rake`) against this project's own off-screen GLES3
  context, fixing three real upstream gaps in the process (a missing
  `<EGL/egl.h>` include on desktop Linux, two undeclared GL enums under pure
  GLES3, and an OpenAL dependency this build never needs). Added
  `MV::Effekseer.smoke_test`/`.available?` (`mruby-mvjs/src/mvefk.cxx`),
  which creates a real GLES3 context, loads a real, unmodified `.efkefc`
  effect file, and drives it through Effekseer's own particle simulation and
  render pipeline end to end with zero GL errors -- proven against 91 real
  effect files shipping with a real downloaded MZ release. This is a
  foundational milestone, not full particle rendering yet: simulation is
  confirmed live and correct, but a further, not-yet-isolated culling or
  submission gate still keeps every particle from reaching an actual GPU
  draw call (see docs/adr/0004's own write-up for the exact diagnostic
  state). `js/libs/effekseer.min.js`'s JS-bridge wiring is a separate,
  deliberately staged follow-up.
