// Shared declarations for the MV JavaScript host (see mvjs.cxx). The host is
// split across translation units so each concern (engine/globals vs the
// Canvas2D bridge) stays readable; each `mv_install_*` adds its natives and JS
// shims to the one persistent context.
#pragma once

#include <quickjs.h>

// Install the Canvas2D bridge: document.createElement('canvas'), the
// CanvasRenderingContext2D shim and the native RGBA-buffer canvas registry it
// draws into. Defined in mvcanvas.cxx.
void mv_install_canvas(JSContext* ctx);
