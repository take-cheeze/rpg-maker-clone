// Off-screen GLES2 backend for the JavaScript makers' WebGL path (milestone
// M6.3a — foundation).
//
// RPG Maker MZ ships PIXI v5, which is WebGL-only: there is no Canvas2D
// renderer to map onto the `Canvas2D -> Bitmap` bridge the MV path uses
// (mvcanvas.cxx). So MZ needs a real GLES2 context — but the whole renderer is
// software (LVGL + CPU RGBA buffers, presented to SDL and the terminals alike),
// with no GPU anywhere. A surfaceless EGL context over llvmpipe fills exactly
// that gap: EGL's `EGL_MESA_platform_surfaceless` platform needs no window
// system or device node, llvmpipe is Mesa's CPU rasteriser, and the GLES2 entry
// points come from `libGLESv2`. We render into an FBO and read it back to an
// RGBA8 buffer. Critically, the GLSL compiler accepts the GLSL ES 1.00 shaders
// PIXI v5 emits (`#version 100`, `attribute`/`varying`, `precision`), so no
// shader-translation layer is needed. (This began on OSMesa; Mesa removed that
// frontend, and surfaceless EGL is its supported replacement.)
//
// This header is the thin C++ surface the rest of the gem (and, later, the
// WebGL JS shim in mvcanvas.cxx — M6.3b) drives. M6.3a lands the context
// plumbing plus a self-test that proves the pipeline end to end; the full
// WebGLRenderingContext method mapping and `getContext('webgl')` wiring follow.

#ifndef MRUBY_MVJS_MVGL_HXX
#define MRUBY_MVJS_MVGL_HXX

#include <cstdint>

namespace mvgl {

// An off-screen GLES2 context bound to an internal RGBA8 colour buffer of
// `width` x `height`. Opaque; created via `create`, freed via `destroy`.
struct Context;

// Create a surfaceless EGL GLES2 context with a fresh RGBA8 render target,
// making it current on the calling thread. Returns nullptr on failure (and logs
// why to stderr). Software-only: needs no display, GPU or window, so it works
// in headless CI exactly as on a desktop.
Context* create(int width, int height);

// Destroy a context created by `create` and free its colour buffer.
void destroy(Context* ctx);

// Re-bind `ctx` as the current context on the calling thread (several contexts
// can exist; GL calls act on whichever is current). Returns false on failure.
bool make_current(Context* ctx);

// Re-specify the context's render target at `width` x `height`, keeping the
// same FBO and attachment points. The JS makers create their WebGL context from
// a canvas that is still 0x0 (clamped to 1x1 here) and only size it once the
// engine knows its screen resolution — MZ does exactly that, in
// Scene_Boot.resizeScreen -> Graphics.resize -> the canvas' width/height
// setters — so without this the whole game renders into a 1x1 target and both
// the on-screen present and the screenshot read back a single pixel. A no-op
// (returning true) when the size is unchanged; false on failure or a stub
// context.
bool resize(Context* ctx, int width, int height);

// The context's colour buffer as top-down RGBA8 (GL renders bottom-up; this
// returns it flipped so it drops straight into the present path, matching the
// MV canvas). `*out_w`/`*out_h` receive the dimensions. The pointer is owned by
// the context and valid until the next draw or `destroy`.
const std::uint8_t* pixels(Context* ctx, int* out_w, int* out_h);

// The GL name of the context's own framebuffer object (the off-screen render
// target). WebGL's "default framebuffer" — what `bindFramebuffer(target, null)`
// selects — is this FBO, not GL framebuffer 0 (a surfaceless EGL context has no
// window-system default framebuffer). The WebGL wrapper (mvwebgl.cxx) binds
// this when the game unbinds its own framebuffers. Returns 0 for a stub
// context.
unsigned default_framebuffer(Context* ctx);

// Whether the EGL/GLES2 backend was compiled into this build. False on
// Emscripten (browser WebGL) and where the EGL headers are absent (e.g.
// darwin); in that case the other entry points are inert stubs. True on the apt
// and nix builds. Callers should check this before relying on
// `create`/`smoke_test`.
bool available();

// End-to-end self-test of the pipeline, independent of any game: create a small
// context, compile the PIXI-style GLES2 (ES 1.00) shaders, draw a full-screen
// green triangle, and read the centre pixel back. On success returns true and
// writes the centre pixel into `out_rgba` (bytes R,G,B,A); on any failure logs
// the GL detail to stderr and returns false. This is what CI exercises, since
// it needs no proprietary MZ engine.
bool smoke_test(std::uint8_t out_rgba[4]);

}  // namespace mvgl

#endif  // MRUBY_MVJS_MVGL_HXX
