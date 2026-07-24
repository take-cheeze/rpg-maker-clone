// The Canvas2D -> RGBA-buffer bridge for RPG Maker MV support (milestone M4).
//
// MV renders through PIXI.js. Its WebGL renderer needs a real GL context, so we
// return null for 'webgl' (see the canvas getContext shim) and PIXI falls back
// to its Canvas2D renderer, which draws through a CanvasRenderingContext2D.
// This file backs those canvases with plain RGBA8 buffers and implements the
// subset of the 2D API PIXI's canvas path and MV's Bitmap use.
//
// Keeping the canvas a self-contained byte buffer (rather than an
// mruby-rgss::Bitmap) makes the drawing primitives independent of the display
// and unit-testable by reading pixels back. Presenting the main canvas
// on-screen (copying it into a Sprite's Bitmap each frame) is a separate, thin
// step handled with the game loop.

#include "mvhost.hxx"

#include <cstdint>
#include <cstring>
#include <vector>

namespace {

// An RGBA8 canvas, row-major, straight (non-premultiplied) alpha.
struct Canvas {
  int w = 0;
  int h = 0;
  std::vector<uint8_t> px;

  void resize(int nw, int nh) {
    w = nw < 0 ? 0 : nw;
    h = nh < 0 ? 0 : nh;
    px.assign(static_cast<size_t>(w) * static_cast<size_t>(h) * 4, 0);
  }
};

// Canvases are referenced from JS by an integer handle (index + 1; 0 is the
// null handle). They live for the process for now; disposal lands with the
// bitmap lifetime work.
std::vector<Canvas*> g_canvases;

Canvas* canvas_get(int handle) {
  if (handle < 1 || static_cast<size_t>(handle) > g_canvases.size())
    return nullptr;
  return g_canvases[static_cast<size_t>(handle) - 1];
}

// Source-over alpha blend of (r,g,b,a) onto the RGBA pixel at `d`.
void blend(uint8_t* d, int r, int g, int b, int a) {
  if (a <= 0)
    return;
  if (a >= 255) {
    d[0] = static_cast<uint8_t>(r);
    d[1] = static_cast<uint8_t>(g);
    d[2] = static_cast<uint8_t>(b);
    d[3] = 255;
    return;
  }
  const int ia = 255 - a;
  d[0] = static_cast<uint8_t>((r * a + d[0] * ia) / 255);
  d[1] = static_cast<uint8_t>((g * a + d[1] * ia) / 255);
  d[2] = static_cast<uint8_t>((b * a + d[2] * ia) / 255);
  d[3] = static_cast<uint8_t>((a * 255 + d[3] * ia) / 255);
}

int ai(JSContext* ctx, int argc, JSValueConst* argv, int i) {
  int32_t v = 0;
  if (i < argc)
    JS_ToInt32(ctx, &v, argv[i]);
  return v;
}

// __mv_canvasCreate(w, h) -> handle
JSValue js_create(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
  Canvas* c = new Canvas();
  c->resize(ai(ctx, argc, argv, 0), ai(ctx, argc, argv, 1));
  g_canvases.push_back(c);
  return JS_NewInt32(ctx, static_cast<int>(g_canvases.size()));
}

// __mv_canvasResize(handle, w, h)
JSValue js_resize(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
  Canvas* c = canvas_get(ai(ctx, argc, argv, 0));
  if (c)
    c->resize(ai(ctx, argc, argv, 1), ai(ctx, argc, argv, 2));
  return JS_UNDEFINED;
}

JSValue js_width(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
  Canvas* c = canvas_get(ai(ctx, argc, argv, 0));
  return JS_NewInt32(ctx, c ? c->w : 0);
}

JSValue js_height(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
  Canvas* c = canvas_get(ai(ctx, argc, argv, 0));
  return JS_NewInt32(ctx, c ? c->h : 0);
}

// __mv_canvasFillRect(handle, x, y, w, h, r, g, b, a)
JSValue js_fill_rect(JSContext* ctx,
                     JSValueConst,
                     int argc,
                     JSValueConst* argv) {
  Canvas* c = canvas_get(ai(ctx, argc, argv, 0));
  if (!c)
    return JS_UNDEFINED;
  int x = ai(ctx, argc, argv, 1), y = ai(ctx, argc, argv, 2);
  int rw = ai(ctx, argc, argv, 3), rh = ai(ctx, argc, argv, 4);
  const int r = ai(ctx, argc, argv, 5), g = ai(ctx, argc, argv, 6);
  const int b = ai(ctx, argc, argv, 7), a = ai(ctx, argc, argv, 8);
  for (int j = 0; j < rh; ++j) {
    const int ty = y + j;
    if (ty < 0 || ty >= c->h)
      continue;
    for (int i = 0; i < rw; ++i) {
      const int tx = x + i;
      if (tx < 0 || tx >= c->w)
        continue;
      blend(&c->px[(static_cast<size_t>(ty) * c->w + tx) * 4], r, g, b, a);
    }
  }
  return JS_UNDEFINED;
}

// __mv_canvasClearRect(handle, x, y, w, h) -> set the rect to transparent
// black.
JSValue js_clear_rect(JSContext* ctx,
                      JSValueConst,
                      int argc,
                      JSValueConst* argv) {
  Canvas* c = canvas_get(ai(ctx, argc, argv, 0));
  if (!c)
    return JS_UNDEFINED;
  int x = ai(ctx, argc, argv, 1), y = ai(ctx, argc, argv, 2);
  int rw = ai(ctx, argc, argv, 3), rh = ai(ctx, argc, argv, 4);
  for (int j = 0; j < rh; ++j) {
    const int ty = y + j;
    if (ty < 0 || ty >= c->h)
      continue;
    for (int i = 0; i < rw; ++i) {
      const int tx = x + i;
      if (tx < 0 || tx >= c->w)
        continue;
      std::memset(&c->px[(static_cast<size_t>(ty) * c->w + tx) * 4], 0, 4);
    }
  }
  return JS_UNDEFINED;
}

// __mv_canvasDrawImage(dstH, srcH, sx, sy, sw, sh, dx, dy, dw, dh, alpha)
// Nearest-neighbour scaled blit of a source rect into a dest rect, modulated by
// a global alpha (0-255). This is the workhorse PIXI's canvas renderer uses.
JSValue js_draw_image(JSContext* ctx,
                      JSValueConst,
                      int argc,
                      JSValueConst* argv) {
  Canvas* d = canvas_get(ai(ctx, argc, argv, 0));
  Canvas* s = canvas_get(ai(ctx, argc, argv, 1));
  if (!d || !s)
    return JS_UNDEFINED;
  const int sx = ai(ctx, argc, argv, 2), sy = ai(ctx, argc, argv, 3);
  const int sw = ai(ctx, argc, argv, 4), sh = ai(ctx, argc, argv, 5);
  const int dx = ai(ctx, argc, argv, 6), dy = ai(ctx, argc, argv, 7);
  const int dw = ai(ctx, argc, argv, 8), dh = ai(ctx, argc, argv, 9);
  const int ga = argc > 10 ? ai(ctx, argc, argv, 10) : 255;
  if (dw <= 0 || dh <= 0 || sw <= 0 || sh <= 0)
    return JS_UNDEFINED;
  for (int oy = 0; oy < dh; ++oy) {
    const int ty = dy + oy;
    if (ty < 0 || ty >= d->h)
      continue;
    const int syy = sy + oy * sh / dh;
    if (syy < 0 || syy >= s->h)
      continue;
    for (int ox = 0; ox < dw; ++ox) {
      const int tx = dx + ox;
      if (tx < 0 || tx >= d->w)
        continue;
      const int sxx = sx + ox * sw / dw;
      if (sxx < 0 || sxx >= s->w)
        continue;
      const uint8_t* sp = &s->px[(static_cast<size_t>(syy) * s->w + sxx) * 4];
      const int a = sp[3] * ga / 255;
      blend(&d->px[(static_cast<size_t>(ty) * d->w + tx) * 4], sp[0], sp[1],
            sp[2], a);
    }
  }
  return JS_UNDEFINED;
}

// __mv_canvasGetPixel(handle, x, y) -> [r, g, b, a] (used by tests and by the
// getImageData path). Out-of-range reads return transparent black.
JSValue js_get_pixel(JSContext* ctx,
                     JSValueConst,
                     int argc,
                     JSValueConst* argv) {
  Canvas* c = canvas_get(ai(ctx, argc, argv, 0));
  const int x = ai(ctx, argc, argv, 1), y = ai(ctx, argc, argv, 2);
  JSValue arr = JS_NewArray(ctx);
  uint8_t out[4] = {0, 0, 0, 0};
  if (c && x >= 0 && x < c->w && y >= 0 && y < c->h)
    std::memcpy(out, &c->px[(static_cast<size_t>(y) * c->w + x) * 4], 4);
  for (uint32_t k = 0; k < 4; ++k)
    JS_SetPropertyUint32(ctx, arr, k, JS_NewInt32(ctx, out[k]));
  return arr;
}

// The Canvas2D JavaScript shim: document, HTMLCanvasElement and the 2D context.
const char* kCanvasPreamble = R"MVJS(
(function (g) {
  function parseColor(s) {
    if (typeof s !== 'string') return [0, 0, 0, 255];
    s = s.trim();
    if (s.charAt(0) === '#') {
      if (s.length === 4) {
        return [parseInt(s.charAt(1) + s.charAt(1), 16),
                parseInt(s.charAt(2) + s.charAt(2), 16),
                parseInt(s.charAt(3) + s.charAt(3), 16), 255];
      }
      return [parseInt(s.substr(1, 2), 16), parseInt(s.substr(3, 2), 16),
              parseInt(s.substr(5, 2), 16), 255];
    }
    var m = s.match(/rgba?\(([^)]+)\)/);
    if (m) {
      var p = m[1].split(',');
      return [parseInt(p[0], 10) || 0, parseInt(p[1], 10) || 0,
              parseInt(p[2], 10) || 0,
              p.length > 3 ? Math.round(parseFloat(p[3]) * 255) : 255];
    }
    return [0, 0, 0, 255];
  }

  function Ctx(h) {
    this.__h = h;
    this.canvas = null;
    this.fillStyle = '#000000';
    this.strokeStyle = '#000000';
    this.globalAlpha = 1;
    this.globalCompositeOperation = 'source-over';
    this.font = '10px sans-serif';
    this.textAlign = 'left';
    this.textBaseline = 'alphabetic';
    this.lineWidth = 1;
    this.imageSmoothingEnabled = true;
  }
  Ctx.prototype.fillRect = function (x, y, w, h) {
    var c = parseColor(this.fillStyle);
    var a = Math.round(c[3] * this.globalAlpha);
    g.__mv_canvasFillRect(this.__h, x | 0, y | 0, w | 0, h | 0, c[0], c[1], c[2], a);
  };
  Ctx.prototype.clearRect = function (x, y, w, h) {
    g.__mv_canvasClearRect(this.__h, x | 0, y | 0, w | 0, h | 0);
  };
  function srcHandle(img) {
    if (!img) return 0;
    if (img.__h) return img.__h;
    if (img._canvas && img._canvas.__h) return img._canvas.__h;
    return 0;
  }
  Ctx.prototype.drawImage = function (img) {
    var h = srcHandle(img);
    if (!h) return;
    var iw = img.width || 0, ih = img.height || 0;
    var a = Math.round(this.globalAlpha * 255);
    if (arguments.length <= 3) {
      g.__mv_canvasDrawImage(this.__h, h, 0, 0, iw, ih,
                             arguments[1] | 0, arguments[2] | 0, iw, ih, a);
    } else if (arguments.length <= 5) {
      g.__mv_canvasDrawImage(this.__h, h, 0, 0, iw, ih, arguments[1] | 0,
                             arguments[2] | 0, arguments[3] | 0,
                             arguments[4] | 0, a);
    } else {
      g.__mv_canvasDrawImage(this.__h, h, arguments[1] | 0, arguments[2] | 0,
                             arguments[3] | 0, arguments[4] | 0,
                             arguments[5] | 0, arguments[6] | 0,
                             arguments[7] | 0, arguments[8] | 0, a);
    }
  };
  Ctx.prototype.getImageData = function (x, y, w, h) {
    w = w | 0; h = h | 0;
    var data = [];
    for (var j = 0; j < h; j++) {
      for (var i = 0; i < w; i++) {
        var p = g.__mv_canvasGetPixel(this.__h, (x | 0) + i, (y | 0) + j);
        data.push(p[0], p[1], p[2], p[3]);
      }
    }
    return { width: w, height: h, data: data };
  };
  Ctx.prototype.measureText = function (t) {
    return { width: (t ? String(t).length : 0) * 6 };
  };
  // Path, transform and text operations MV/PIXI call but that the buffer path
  // does not need yet: accept and ignore. Real implementations land as needed.
  var noops = ['save', 'restore', 'beginPath', 'closePath', 'moveTo', 'lineTo',
    'arc', 'arcTo', 'rect', 'fill', 'stroke', 'clip', 'translate', 'scale',
    'rotate', 'transform', 'setTransform', 'resetTransform', 'fillText',
    'strokeText', 'setLineDash', 'putImageData', 'createLinearGradient',
    'createRadialGradient', 'createPattern', 'drawFocusIfNeeded', 'scrollPathIntoView'];
  noops.forEach(function (m) {
    if (!Ctx.prototype[m]) Ctx.prototype[m] = function () {};
  });

  function Canvas(w, h) {
    var self = this;
    this._w = w || 0;
    this._h = h || 0;
    this.__h = g.__mv_canvasCreate(this._w, this._h);
    this._ctx = null;
    this.style = {};
    Object.defineProperty(this, 'width', {
      get: function () { return self._w; },
      set: function (v) { self._w = v | 0; g.__mv_canvasResize(self.__h, self._w, self._h); },
    });
    Object.defineProperty(this, 'height', {
      get: function () { return self._h; },
      set: function (v) { self._h = v | 0; g.__mv_canvasResize(self.__h, self._w, self._h); },
    });
  }
  Canvas.prototype.getContext = function (type) {
    if (type === '2d') {
      if (!this._ctx) { this._ctx = new Ctx(this.__h); this._ctx.canvas = this; }
      return this._ctx;
    }
    return null;  // no WebGL -> PIXI uses its Canvas renderer
  };
  Canvas.prototype.addEventListener = function () {};
  Canvas.prototype.removeEventListener = function () {};
  Canvas.prototype.getBoundingClientRect = function () {
    return { left: 0, top: 0, right: this._w, bottom: this._h,
             width: this._w, height: this._h };
  };
  g.HTMLCanvasElement = Canvas;

  function stubElement(tag) {
    return {
      tagName: tag, style: {}, dataset: {}, className: '',
      getContext: function () { return null; },
      appendChild: function () {}, removeChild: function () {},
      setAttribute: function () {}, getAttribute: function () { return null; },
      addEventListener: function () {}, removeEventListener: function () {},
    };
  }
  g.document = {
    createElement: function (tag) {
      tag = ('' + tag).toLowerCase();
      return tag === 'canvas' ? new Canvas() : stubElement(tag);
    },
    getElementById: function () { return null; },
    getElementsByTagName: function () { return []; },
    createEvent: function () { return { initEvent: function () {} }; },
    addEventListener: function () {}, removeEventListener: function () {},
    body: { appendChild: function () {}, style: {}, addEventListener: function () {} },
    documentElement: { style: {} },
    head: { appendChild: function () {} },
  };
})(this);
)MVJS";

void install(JSContext* ctx,
             JSValue global,
             const char* name,
             JSCFunction* fn,
             int argc) {
  JS_SetPropertyStr(ctx, global, name, JS_NewCFunction(ctx, fn, name, argc));
}

}  // namespace

void mv_install_canvas(JSContext* ctx) {
  JSValue global = JS_GetGlobalObject(ctx);
  install(ctx, global, "__mv_canvasCreate", js_create, 2);
  install(ctx, global, "__mv_canvasResize", js_resize, 3);
  install(ctx, global, "__mv_canvasWidth", js_width, 1);
  install(ctx, global, "__mv_canvasHeight", js_height, 1);
  install(ctx, global, "__mv_canvasFillRect", js_fill_rect, 9);
  install(ctx, global, "__mv_canvasClearRect", js_clear_rect, 5);
  install(ctx, global, "__mv_canvasDrawImage", js_draw_image, 11);
  install(ctx, global, "__mv_canvasGetPixel", js_get_pixel, 3);
  JS_FreeValue(ctx, global);

  JSValue r = JS_Eval(ctx, kCanvasPreamble, std::strlen(kCanvasPreamble),
                      "<mv-canvas-preamble>", JS_EVAL_TYPE_GLOBAL);
  JS_FreeValue(ctx, r);
}
