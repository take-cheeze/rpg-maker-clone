// Shared declarations for the MV JavaScript host (see mvjs.cxx). The host is
// split across translation units so each concern (engine/globals vs the
// Canvas2D bridge) stays readable; each `mv_install_*` adds its natives and JS
// shims to the one persistent context.
#pragma once

#include <string>

#include <quickjs.h>

// Install the Canvas2D bridge: document.createElement('canvas'), the
// CanvasRenderingContext2D shim and the native RGBA-buffer canvas registry it
// draws into. Defined in mvcanvas.cxx.
void mv_install_canvas(JSContext* ctx);

// Resolve a game-relative asset path against the configured game base dir (set
// from Ruby via `MV::JS.base_dir=`). MV's own JavaScript requests data/assets
// with paths relative to the game root (e.g. `data/System.json`, `img/...`),
// but the process is not chdir'd into the game dir, so these must be rooted
// here. Absolute paths and paths already under the base dir are returned
// unchanged. Defined in mvjs.cxx and shared with the Canvas2D image loader.
std::string mv_resolve_path(const std::string& p);
