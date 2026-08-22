// Native Effekseer integration — the real particle engine RPG Maker MZ ships
// as `js/libs/effekseer.min.js`, built here against the vendored C++ SDK
// (3rd/effekseer, github.com/effekseer/Effekseer, MIT, pinned to tag 1807)
// and the same off-screen GLES3 context mvgl.cxx already exposes.
//
// `smoke_test` below lands the foundational, isolated proof that the GL
// integration actually works: it loads a real, unmodified `.efkefc` effect
// file (91 of them are vendored under a real downloaded MZ game's own
// `effects/` folder for exactly this) and renders it through Effekseer's own
// GLES renderer into an mvgl::Context, independent of the JS/PIXI stack,
// confirmed to produce real GPU draw calls and visible pixels. That was
// deliberately staged ahead of wiring `MZ::EFFEKSEER_SHIM_JS`'s no-ops to
// real native calls (ADR 0004's own recommendation): reconciling Effekseer's
// GL state and matrix conventions against a real GLES driver, with no browser
// reference to diff against in this headless environment, was the actual
// risk there — proving it in isolation first meant a JS-bridge bug and a
// GL-integration bug were never both in play in the same debugging session.
//
// The context/effect/handle API below is the first half of that JS-bridge
// wiring: real `Effekseer::Manager` simulation, still no rendering (see its
// own comment for why that half is staged separately).

#ifndef MRUBY_MVJS_MVEFK_HXX
#define MRUBY_MVJS_MVEFK_HXX

#include <cstddef>
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

// Persistent per-game simulation context for the JS bridge
// (MZ::EFFEKSEER_SHIM_JS's `window.effekseer.createContext()`). Backed by a
// real `Effekseer::Manager`, so a loaded, valid `.efkefc` effect really
// simulates (spawns, moves and expires real particle instances) instead of
// the shim's old synthetic fixed-lifetime handle.
//
// Deliberately renderer-less: no `EffekseerRendererGL::Renderer`, no GL
// context. Simulation needs neither, and drawing real MZ animations needs
// Effekseer's renderer to share the exact GL context/FBO PIXI's own WebGL
// renderer (mvwebgl.cxx) is using mid-frame -- a separate, higher-risk
// integration staged as its own follow-up (see docs/TODO.md's Effekseer
// entry). Until that lands, a context created here never draws anything;
// it only makes handle.exists/animation timing reflect a real, deterministic
// simulation instead of an arbitrary placeholder.
//
// Every function below silently no-ops/returns a failure sentinel (0 for a
// ContextId/EffectId, -1 for a play handle, false for exists) when called on
// an invalid id or where `available()` is false, so callers never need to
// branch on backend availability beyond checking `available()` once.
using ContextId = std::uint32_t;  // 0 is never a valid context.
using EffectId = std::uint32_t;   // 0 means "no native effect" (never valid).

// Backed by a real Effekseer::Manager. 0 on failure (backend unavailable).
ContextId context_create();
void context_destroy(ContextId ctx);

// Parses `bytes` (length `len`) as a real `.efkefc` file via
// `Effekseer::Effect::Create`, so this can and does fail (return 0) for
// content that merely *looks* like one (e.g. right magic bytes, garbage
// after) -- the JS bridge treats that identically to "no native effect
// available", not as a load error: EFFEKSEER_SHIM_JS's own honest-reporting
// magic-byte check is unrelated and unaffected either way.
EffectId effect_load(ContextId ctx,
                     const std::uint8_t* bytes,
                     std::size_t len,
                     float magnification);
void effect_release(ContextId ctx, EffectId effect);

// Effekseer::Handle is a plain int32_t; -1 means Play failed (bad context,
// bad/unloaded effect, or the manager's instance cap).
std::int32_t play(ContextId ctx, EffectId effect, float x, float y, float z);
void set_location(ContextId ctx,
                  std::int32_t handle,
                  float x,
                  float y,
                  float z);
void set_rotation(ContextId ctx,
                  std::int32_t handle,
                  float x,
                  float y,
                  float z);
void set_scale(ContextId ctx, std::int32_t handle, float x, float y, float z);
void set_speed(ContextId ctx, std::int32_t handle, float speed);
void stop(ContextId ctx, std::int32_t handle);
bool handle_exists(ContextId ctx, std::int32_t handle);

void update(ContextId ctx, float delta_frame);
void stop_all(ContextId ctx);

}  // namespace mvefk

#endif  // MRUBY_MVJS_MVEFK_HXX
