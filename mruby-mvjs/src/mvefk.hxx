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
// `context_create` alone is still renderer-less (mirrors the real
// `effekseer.js` API: `createContext()` builds the JS-visible object but does
// not touch GL -- see its own `init(webglContext, settings)` method, which is
// what the real WASM build's `Core.Init` call happens inside). `init_render`
// below is that second step for this native backend: it attaches a real
// `EffekseerRendererGL::Renderer` to the manager, sharing whatever GL context
// is current on this thread at the moment it is called -- which is exactly
// why the JS bridge's `ctx.init(gl)` (called by `Graphics._createEffekseerContext`
// right after PIXI's own WebGL context is built, per rmmz_core.js) resolves
// the JS-side `WebGLRenderingContext` handle to a native one first
// (`mv_webgl_make_current`, mvhost.hxx) before calling this. Until `init_render`
// succeeds, a context behaves exactly as before this was added: simulation
// only, `begin_draw`/`draw_handle`/`end_draw` are no-ops.
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
//
// `path` is the same game-relative URL `loadEffect(url, ...)` was given
// (e.g. "effects/Flash.efkefc"), used only to derive Effekseer's
// `materialPath` -- the directory every texture/model/material the effect
// references is resolved against (see `Effekseer::Effect::Create`'s
// `char16_t*`-path overload, Effekseer.Effect.cpp, which derives this same
// directory automatically; the byte-buffer overload used here cannot, since
// it never sees a path at all). Without this, every such reference resolves
// against an empty `materialPath` -- i.e. the bare relative name, never a
// real file relative to this process' CWD -- so `ResourceManager::LoadTexture`
// silently returns null and the effect's sprite/ring nodes have nothing to
// draw: real, alive instances (`Manager::GetTotalInstanceCount() > 0`) but
// `Renderer::GetDrawCallCount() == 0`, with no GL error and no diagnostic
// from either library. May be null/empty (no materialPath is threaded
// through then, matching this function's old, pre-rendering behavior) --
// simulation-only callers never needed it.
EffectId effect_load(ContextId ctx,
                     const std::uint8_t* bytes,
                     std::size_t len,
                     float magnification,
                     const char* path);
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

// Attach a real `EffekseerRendererGL::Renderer` to `ctx`'s manager, sharing
// whatever GL context/FBO is current on this thread right now -- the caller
// (`js_efk_init`, mvefk.cxx) is responsible for making the right one current
// first via `mv_webgl_make_current`. Idempotent: a second call on a context
// that already has a renderer is a no-op returning true, mirroring the real
// `effekseer.js` API (`init` can be called again if PIXI ever recreated its
// context) and, more immediately, letting a re-evaluated EFFEKSEER_SHIM_JS
// not build a second renderer stacked on the first.
//
// False on failure (invalid context, `Renderer::Create` itself failing --
// e.g. no GL context is actually current) and true otherwise. A context
// whose renderer failed to attach behaves exactly as a renderer-less one:
// `begin_draw`/`draw_handle`/`end_draw` stay no-ops, never crashes.
bool init_render(ContextId ctx);

// `renderer->SetProjectionMatrix`/`SetCameraMatrix`, fed the 16 floats of an
// `Effekseer::Matrix44` in exactly the flat layout MZ's own
// `Sprite_Animation.setProjectionMatrix`/`setCameraMatrix` (rmmz_sprites.js)
// build their JS arrays in -- the same bit-for-bit copy the real
// `effekseer.js` wrapper does (`Module.HEAPF32.set(matrixArray, ...)` then a
// raw native pointer), so no row/column-major translation happens on either
// side of this call. A no-op where `ctx` has no renderer attached yet.
void set_projection_matrix(ContextId ctx, const float m[16]);
void set_camera_matrix(ContextId ctx, const float m[16]);

// `renderer->BeginRendering()`/`renderer->EndRendering()`. Per
// `EffekseerRendererGL::RendererImplemented`'s own source
// (3rd/effekseer/.../EffekseerRendererGL.Renderer.cpp), these save and
// restore every piece of GL state the renderer itself touches (bound
// program/VAO/buffers/textures, blend/depth/cull state) but never the
// framebuffer binding, viewport or scissor -- so nesting a
// begin/draw*/end inside PIXI's own mid-frame render pass (as
// `Sprite_Animation._render` does) cannot corrupt PIXI's own GL state, and
// draws into whichever FBO PIXI already has bound. A no-op where `ctx` has
// no renderer attached yet.
void begin_draw(ContextId ctx);
void end_draw(ContextId ctx);

// `manager->DrawHandle(handle, draw_param)`, with `draw_param`'s
// `ViewProjectionMatrix` set from `renderer->GetCameraProjectionMatrix()` --
// which only reflects the most recent `set_projection_matrix`/
// `set_camera_matrix` calls once `begin_draw` has actually run (see
// `smoke_test`'s own comment on this exact pitfall). Must be called between
// `begin_draw` and `end_draw`, matching MZ's own call order
// (`Sprite_Animation._render`: setProjectionMatrix, setCameraMatrix,
// beginDraw, drawHandle, endDraw). `ZNear`/`ZFar` are left at
// `DrawParameter`'s own default (0.0f, equal), which skips `CanDraw`'s
// CPU-side sphere-culling check entirely (`Effekseer.Manager.cpp` only runs
// it `if (ZNear != ZFar)`) -- exactly what the real WASM wrapper's own
// `drawHandle(handle)` does too (it takes no near/far/camera-position
// arguments at all; effekseer.min.js's `Core.DrawHandle(ptr, handle.native)`
// is the whole call). A no-op where `ctx` has no renderer attached yet or
// `handle` is negative (Play failed).
void draw_handle(ContextId ctx, std::int32_t handle);

}  // namespace mvefk

#endif  // MRUBY_MVJS_MVEFK_HXX
