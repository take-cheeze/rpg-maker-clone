// Native Effekseer integration — the real particle engine RPG Maker MZ ships
// as `js/libs/effekseer.min.js`, built here against the vendored C++ SDK
// (3rd/effekseer, github.com/effekseer/Effekseer, MIT, pinned to tag 1807)
// and the same off-screen GLES3 context mvgl.cxx already exposes.
//
// This header lands the foundational, isolated proof that the GL integration
// actually works — `smoke_test` below loads a real, unmodified `.efkefc`
// effect file (91 of them are vendored under a real downloaded MZ game's own
// `effects/` folder for exactly this) and renders it through Effekseer's own
// GLES renderer into an mvgl::Context, independent of the JS/PIXI stack. This
// is deliberately staged ahead of wiring `MZ::EFFEKSEER_SHIM_JS`'s no-ops to
// real native calls (ADR 0004's own recommendation): reconciling Effekseer's
// GL state and matrix conventions against a real GLES driver, with no browser
// reference to diff against in this headless environment, is the actual risk
// here — proving it in isolation first means a JS-bridge bug and a
// GL-integration bug are never both in play in the same debugging session.

#ifndef MRUBY_MVJS_MVEFK_HXX
#define MRUBY_MVJS_MVEFK_HXX

#include <cstdint>

namespace mvefk {

// Whether the Effekseer backend was compiled into this build. False wherever
// mvgl's real EGL/GLES backend is not (Emscripten, a build missing the EGL/
// GLES headers) or the GLES3 header specifically is absent (Effekseer's own
// GraphicsDevice.cpp needs real ES3, not just ES2 — see CMakeLists.txt's own
// comment on this). Callers should check this before relying on
// `smoke_test`.
bool available();

// End-to-end self-test of the native Effekseer pipeline, independent of any
// JS/PIXI code: create a small off-screen GLES3 context (mvgl.cxx), stand up
// an `Effekseer::Manager` + `EffekseerRendererGL::Renderer` bound to it, load
// the real `.efkefc` file at `path`, play it, step its simulation forward
// `warmup_frames` times, draw one frame, and read the result back.
//
// On success returns true and writes the count of rendered pixels that
// differ from the clear colour into `*out_lit_pixel_count` — the cheapest
// possible proof that Effekseer actually drew *something* into the context
// mvgl.cxx owns, as opposed to loading and simulating the effect but
// rendering nothing (a real, silent failure mode: a matrix or GL-state
// mismatch can leave `Draw` a no-op with no error from either library). A
// non-zero count is not proof the *specific* effect rendered correctly, only
// that the GL integration itself produces pixels; it is the foundational
// check this milestone needs; a scoped-image / visual-diff check is a
// follow-up once the JS bridge exists to drive real MZ animations to compare
// against.
//
// On any failure (file missing/unparseable, GL context creation failure, a
// null renderer/manager) logs the reason to stderr and returns false.
bool smoke_test(const char* path,
                int width,
                int height,
                int warmup_frames,
                std::uint32_t* out_lit_pixel_count);

}  // namespace mvefk

#endif  // MRUBY_MVJS_MVEFK_HXX
