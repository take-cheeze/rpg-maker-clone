// Off-screen GLES2 backend for the JavaScript makers' WebGL path (milestone
// M6.3a — foundation).
//
// RPG Maker MZ ships PIXI v5, which is WebGL-only: there is no Canvas2D
// renderer to map onto the `Canvas2D -> Bitmap` bridge the MV path uses
// (mvcanvas.cxx). So MZ needs a real GLES2 context — but the whole renderer is
// software (LVGL + CPU RGBA buffers, presented to SDL and the terminals alike),
// with no GPU anywhere. OSMesa fills exactly that gap: it is Mesa's off-screen
// software rasteriser, rendering straight into a caller-owned RGBA8 buffer, and
// its context drives the GLES2 entry points from `libGLESv2`. Critically, its
// GLSL compiler accepts the GLSL ES 1.00 shaders PIXI v5 emits (`#version 100`,
// `attribute`/`varying`, `precision`), so no shader-translation layer is
// needed.
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

// Create an OSMesa GLES2 context and bind it to a fresh RGBA8 buffer, making it
// current on the calling thread. Returns nullptr on failure (and logs why to
// stderr). Software-only: needs no display, GPU or window, so it works in
// headless CI exactly as on a desktop.
Context* create(int width, int height);

// Destroy a context created by `create` and free its colour buffer.
void destroy(Context* ctx);

// Re-bind `ctx` as the current context on the calling thread (several contexts
// can exist; GL calls act on whichever is current). Returns false on failure.
bool make_current(Context* ctx);

// The context's colour buffer as top-down RGBA8 (GL renders bottom-up; this
// returns it flipped so it drops straight into the present path, matching the
// MV canvas). `*out_w`/`*out_h` receive the dimensions. The pointer is owned by
// the context and valid until the next draw or `destroy`.
const std::uint8_t* pixels(Context* ctx, int* out_w, int* out_h);

// Whether the OSMesa/GLES2 backend was compiled into this build. False on
// Emscripten (browser WebGL) and where the OSMesa headers are absent (e.g. the
// nix build until OSMesa is packaged); in that case the other entry points are
// inert stubs. Callers should check this before relying on
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
