// Shared declarations for the MV JavaScript host (see mvjs.cxx). The host is
// split across translation units so each concern (engine/globals vs the
// Canvas2D bridge) stays readable; each `mv_install_*` adds its natives and JS
// shims to the one persistent context.
#pragma once

#include <cstdint>
#include <string>

#include <quickjs.h>

// Install the Canvas2D bridge: document.createElement('canvas'), the
// CanvasRenderingContext2D shim and the native RGBA-buffer canvas registry it
// draws into. Defined in mvcanvas.cxx.
void mv_install_canvas(JSContext* ctx);

// Install the WebGL bridge: the __mv_gl* natives and the WebGLRenderingContext
// prototype that getContext('webgl') returns, backed by the surfaceless-EGL
// GLES2 backend (mvgl.cxx). Called right after mv_install_canvas. A no-op where
// the EGL backend is absent (Emscripten/darwin), which keeps
// getContext('webgl') returning null. Defined in mvwebgl.cxx.
void mv_install_webgl(JSContext* ctx);

// Return the RGBA8 pixel buffer of the canvas registered under `handle` (as
// created by the Canvas2D bridge), setting *w/*h to its dimensions. Returns
// nullptr for an unknown handle. Used to present the MV main canvas on-screen
// each frame. Defined in mvcanvas.cxx.
const uint8_t* mv_canvas_pixels(int handle, int* w, int* h);

// Return the RGBA8 pixel buffer of the WebGL context registered under `handle`
// (as created by getContext('webgl') -> __mv_glCreate), setting *w/*h to its
// dimensions. Reads back the context's FBO, top-down (ready to present,
// matching mv_canvas_pixels' orientation). Returns nullptr for an unknown
// handle or a build without the GL backend. Used to present the MZ WebGL frame
// on-screen. Defined in mvwebgl.cxx.
const uint8_t* mv_webgl_pixels(int handle, int* w, int* h);

// Make the WebGL context registered under `handle` (a WebGLRenderingContext's
// `.__gl` id, as returned by getContext('webgl') -> __mv_glCreate) current on
// this thread and rebind its FBO, exactly as any other `__mv_gl*` call does.
// This is the one place a *different* translation unit (mvefk.cxx) needs to
// resolve that same JS-side handle into the native GL context it names,
// rather than relying on it already being current by incidental call order —
// see mvefk.cxx's `js_efk_init` for why: `Graphics._createEffekseerContext`
// (rmmz_core.js) calls `effekseer.createContext().init(this._app.renderer.gl)`
// right after building PIXI's own WebGL context, and Effekseer's renderer
// must attach to that exact context, not merely "whatever happens to be
// current". Returns false for an unknown handle or a build without the GL
// backend (mvefk's own real branch never runs then either). Defined in
// mvwebgl.cxx.
bool mv_webgl_make_current(int handle);

// Install the Effekseer simulation bridge: the __mv_efk* natives
// `MZ::EFFEKSEER_SHIM_JS` (mz.rb) calls into for real (rather than
// synthetic) effect loading/playback where the native backend is compiled
// in. A no-op registering natives that report "unavailable" where it is not
// (mvefk.cxx's own #else stub branch), which keeps the shim's existing
// diagnostic-only fallback behavior. Defined in mvefk.cxx.
void mv_install_effekseer(JSContext* ctx);

// Resolve a game-relative asset path against the configured game base dir (set
// from Ruby via `MV::JS.base_dir=`). MV's own JavaScript requests data/assets
// with paths relative to the game root (e.g. `data/System.json`, `img/...`),
// but the process is not chdir'd into the game dir, so these must be rooted
// here. Absolute paths and paths already under the base dir are returned
// unchanged. Defined in mvjs.cxx and shared with the Canvas2D image loader.
std::string mv_resolve_path(const std::string& p);

// Unpack `in` to the bare sfnt it wraps if it is a WOFF 1.0 font, or pass it
// through unchanged otherwise. Backs MV::Font.unpack_woff (mvjs.cxx), which
// gives the WOFF unpacker (mvcanvas.cxx) CI coverage independent of the
// game_font() cache -- see that function's comment. Returns false only when
// `in` is a WOFF the unpacker rejects as malformed.
bool mv_font_unpack(const std::string& in, std::string& out);

// Rasterise `codepoint` at `pixel` em size from font bytes given directly
// (WOFF or a bare sfnt) through a fresh stb_truetype font, bypassing the
// game_font() cache. Backs MV::Font.smoke_test (mvjs.cxx). Sets *gw/*gh to
// the glyph bitmap size and *ink to its count of non-zero coverage pixels;
// returns false if the bytes do not parse as a font stb_truetype accepts.
bool mv_font_smoke_test(const std::string& in,
                        int codepoint,
                        double pixel,
                        int* gw,
                        int* gh,
                        int* ink);
