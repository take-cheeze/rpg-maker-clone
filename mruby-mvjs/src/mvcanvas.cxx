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

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

// stb_image is compiled (STB_IMAGE_IMPLEMENTATION) by mruby-rgss (lib.cxx), so
// we include only the declarations here and the decode symbols resolve at link.
#include <stb_image.h>

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

double ad(JSContext* ctx, int argc, JSValueConst* argv, int i, double dflt) {
  double v = dflt;
  if (i < argc)
    JS_ToFloat64(ctx, &v, argv[i]);
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

// __mv_canvasDrawImage(dstH, srcH, sx, sy, sw, sh, dx, dy, dw, dh, alpha,
//                      a, b, c, d, e, f)
// Nearest-neighbour blit of a source rect into a dest rect, modulated by a
// global alpha (0-255) and transformed by the current 2D matrix
// [a b c d e f] (device = (a*u+c*v+e, b*u+d*v+f)). This is the workhorse PIXI's
// canvas renderer uses: it positions every sprite via setTransform, so
// honouring the matrix is what makes sprites land where they belong. The matrix
// defaults to identity, in which case this reduces to a plain scaled blit.
// Rasterised by walking the transformed dest rect's device-space bounding box
// and inverse- mapping each pixel back through the matrix and the dest->source
// scale, so rotation/scale/translation all work and there are no gaps.
JSValue js_draw_image(JSContext* ctx,
                      JSValueConst,
                      int argc,
                      JSValueConst* argv) {
  Canvas* dst = canvas_get(ai(ctx, argc, argv, 0));
  Canvas* src = canvas_get(ai(ctx, argc, argv, 1));
  if (!dst || !src)
    return JS_UNDEFINED;
  const double sx = ad(ctx, argc, argv, 2, 0), sy = ad(ctx, argc, argv, 3, 0);
  const double sw = ad(ctx, argc, argv, 4, 0), sh = ad(ctx, argc, argv, 5, 0);
  const double dx = ad(ctx, argc, argv, 6, 0), dy = ad(ctx, argc, argv, 7, 0);
  const double dw = ad(ctx, argc, argv, 8, 0), dh = ad(ctx, argc, argv, 9, 0);
  const int ga = argc > 10 ? ai(ctx, argc, argv, 10) : 255;
  const double ma = ad(ctx, argc, argv, 11, 1), mb = ad(ctx, argc, argv, 12, 0);
  const double mc = ad(ctx, argc, argv, 13, 0), md = ad(ctx, argc, argv, 14, 1);
  const double me = ad(ctx, argc, argv, 15, 0), mf = ad(ctx, argc, argv, 16, 0);
  if (dw <= 0 || dh <= 0 || sw <= 0 || sh <= 0)
    return JS_UNDEFINED;
  const double det = ma * md - mb * mc;
  if (det == 0)
    return JS_UNDEFINED;
  const double invdet = 1.0 / det;

  // Device-space bounding box of the four transformed dest-rect corners.
  const double cxs[4] = {dx, dx + dw, dx + dw, dx};
  const double cys[4] = {dy, dy, dy + dh, dy + dh};
  double minx = 1e18, miny = 1e18, maxx = -1e18, maxy = -1e18;
  for (int i = 0; i < 4; ++i) {
    const double X = ma * cxs[i] + mc * cys[i] + me;
    const double Y = mb * cxs[i] + md * cys[i] + mf;
    minx = std::min(minx, X);
    maxx = std::max(maxx, X);
    miny = std::min(miny, Y);
    maxy = std::max(maxy, Y);
  }
  int x0 = static_cast<int>(std::floor(minx));
  int y0 = static_cast<int>(std::floor(miny));
  int x1 = static_cast<int>(std::ceil(maxx));
  int y1 = static_cast<int>(std::ceil(maxy));
  x0 = std::max(x0, 0);
  y0 = std::max(y0, 0);
  x1 = std::min(x1, dst->w);
  y1 = std::min(y1, dst->h);

  for (int py = y0; py < y1; ++py) {
    for (int px = x0; px < x1; ++px) {
      // Inverse-transform the device pixel back to user space.
      const double rx = px - me, ry = py - mf;
      const double u = (md * rx - mc * ry) * invdet;
      const double v = (-mb * rx + ma * ry) * invdet;
      if (u < dx || u >= dx + dw || v < dy || v >= dy + dh)
        continue;
      const int sxx = static_cast<int>(sx + (u - dx) * sw / dw);
      const int syy = static_cast<int>(sy + (v - dy) * sh / dh);
      if (sxx < 0 || sxx >= src->w || syy < 0 || syy >= src->h)
        continue;
      const uint8_t* sp =
          &src->px[(static_cast<size_t>(syy) * src->w + sxx) * 4];
      const int a = sp[3] * ga / 255;
      blend(&dst->px[(static_cast<size_t>(py) * dst->w + px) * 4], sp[0], sp[1],
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

// __mv_imageLoad(path) -> a canvas handle holding the decoded image (0 on
// failure). MV's Bitmap loads PNGs through `new Image()`; we decode them with
// stb_image (RGBA8) straight into a canvas so the result can be used as a
// drawImage source, exactly like a canvas. The path is game-relative and rooted
// via mv_resolve_path.
JSValue js_image_load(JSContext* ctx,
                      JSValueConst,
                      int argc,
                      JSValueConst* argv) {
  if (argc < 1)
    return JS_NewInt32(ctx, 0);
  const char* path = JS_ToCString(ctx, argv[0]);
  if (!path)
    return JS_NewInt32(ctx, 0);
  const std::string resolved = mv_resolve_path(path);
  JS_FreeCString(ctx, path);

  int w = 0, h = 0, comp = 0;
  unsigned char* data = stbi_load(resolved.c_str(), &w, &h, &comp, 4);
  if (!data)
    return JS_NewInt32(ctx, 0);

  Canvas* c = new Canvas();
  c->resize(w, h);
  std::memcpy(c->px.data(), data,
              static_cast<size_t>(w) * static_cast<size_t>(h) * 4);
  stbi_image_free(data);
  g_canvases.push_back(c);
  return JS_NewInt32(ctx, static_cast<int>(g_canvases.size()));
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
    this._m = [1, 0, 0, 1, 0, 0];  // current transform (a,b,c,d,e,f)
    this._stack = [];
  }
  // Post-multiply the current matrix by T (canvas semantics: new coordinates are
  // transformed by T first, then the existing matrix).
  function matMul(M, T) {
    return [
      M[0] * T[0] + M[2] * T[1],
      M[1] * T[0] + M[3] * T[1],
      M[0] * T[2] + M[2] * T[3],
      M[1] * T[2] + M[3] * T[3],
      M[0] * T[4] + M[2] * T[5] + M[4],
      M[1] * T[4] + M[3] * T[5] + M[5],
    ];
  }
  Ctx.prototype.save = function () {
    this._stack.push([this._m.slice(), this.globalAlpha, this.fillStyle,
                      this.strokeStyle, this.globalCompositeOperation]);
  };
  Ctx.prototype.restore = function () {
    var s = this._stack.pop();
    if (!s) return;
    this._m = s[0];
    this.globalAlpha = s[1];
    this.fillStyle = s[2];
    this.strokeStyle = s[3];
    this.globalCompositeOperation = s[4];
  };
  Ctx.prototype.translate = function (x, y) { this._m = matMul(this._m, [1, 0, 0, 1, x, y]); };
  Ctx.prototype.scale = function (x, y) { this._m = matMul(this._m, [x, 0, 0, y, 0, 0]); };
  Ctx.prototype.rotate = function (r) {
    var c = Math.cos(r), s = Math.sin(r);
    this._m = matMul(this._m, [c, s, -s, c, 0, 0]);
  };
  Ctx.prototype.transform = function (a, b, c, d, e, f) { this._m = matMul(this._m, [a, b, c, d, e, f]); };
  Ctx.prototype.setTransform = function (a, b, c, d, e, f) { this._m = [a, b, c, d, e, f]; };
  Ctx.prototype.resetTransform = function () { this._m = [1, 0, 0, 1, 0, 0]; };
  // Map the axis-aligned rect (x,y,w,h) through the current matrix to a device
  // rect. Exact for translate/scale (the common case); for rotation/skew this
  // is the rect's bounding box, which is enough for the solid fills MV uses.
  function mapRect(m, x, y, w, h) {
    var x0 = m[0] * x + m[2] * y + m[4], y0 = m[1] * x + m[3] * y + m[5];
    var x1 = m[0] * (x + w) + m[2] * (y + h) + m[4];
    var y1 = m[1] * (x + w) + m[3] * (y + h) + m[5];
    return [Math.round(Math.min(x0, x1)), Math.round(Math.min(y0, y1)),
            Math.round(Math.abs(x1 - x0)), Math.round(Math.abs(y1 - y0))];
  }
  Ctx.prototype.fillRect = function (x, y, w, h) {
    var c = parseColor(this.fillStyle);
    var a = Math.round(c[3] * this.globalAlpha);
    var r = mapRect(this._m, x, y, w, h);
    g.__mv_canvasFillRect(this.__h, r[0], r[1], r[2], r[3], c[0], c[1], c[2], a);
  };
  Ctx.prototype.clearRect = function (x, y, w, h) {
    var r = mapRect(this._m, x, y, w, h);
    g.__mv_canvasClearRect(this.__h, r[0], r[1], r[2], r[3]);
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
    var sx = 0, sy = 0, sw = iw, sh = ih, dx, dy, dw, dh;
    if (arguments.length <= 3) {
      dx = arguments[1]; dy = arguments[2]; dw = iw; dh = ih;
    } else if (arguments.length <= 5) {
      dx = arguments[1]; dy = arguments[2]; dw = arguments[3]; dh = arguments[4];
    } else {
      sx = arguments[1]; sy = arguments[2]; sw = arguments[3]; sh = arguments[4];
      dx = arguments[5]; dy = arguments[6]; dw = arguments[7]; dh = arguments[8];
    }
    var a = Math.round(this.globalAlpha * 255);
    var m = this._m;
    g.__mv_canvasDrawImage(this.__h, h, sx, sy, sw, sh, dx, dy, dw, dh, a,
                           m[0], m[1], m[2], m[3], m[4], m[5]);
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
  // Gradients/patterns: MV's Bitmap.gradientFillRect creates a gradient and
  // chains .addColorStop on it before assigning it to fillStyle, so these must
  // return a real object (a no-op returning undefined would throw). The buffer
  // path doesn't render gradients yet — a gradient fillStyle falls back to
  // opaque black in parseColor — but the calls no longer crash.
  Ctx.prototype.createLinearGradient = function () {
    return { addColorStop: function () {} };
  };
  Ctx.prototype.createRadialGradient = function () {
    return { addColorStop: function () {} };
  };
  Ctx.prototype.createPattern = function () { return {}; };
  // Path and text operations MV/PIXI call but that the buffer path does not need
  // yet: accept and ignore. Real implementations land as needed. (Transform ops
  // — save/restore/translate/scale/rotate/transform/setTransform/resetTransform
  // — are implemented above and deliberately excluded here.)
  var noops = ['beginPath', 'closePath', 'moveTo', 'lineTo',
    'arc', 'arcTo', 'rect', 'fill', 'stroke', 'clip', 'fillText',
    'strokeText', 'setLineDash', 'putImageData',
    'drawFocusIfNeeded', 'scrollPathIntoView'];
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

  // A permissive stand-in for a DOM element. MV attaches error printers, font
  // <style> rules, the mode box and video elements to the document during
  // Graphics.initialize, so the surface here is what that init path touches:
  // child insertion (returning the child, as the DOM does), a CSSStyleSheet with
  // insertRule (font loader), classList, and the usual accessors.
  function stubElement(tag) {
    var el = {
      tagName: ('' + tag).toUpperCase(),
      style: {}, dataset: {}, className: '', id: '', innerHTML: '', textContent: '',
      // <style> elements expose a .sheet whose insertRule the font loader calls.
      sheet: { insertRule: function () {}, deleteRule: function () {}, cssRules: [] },
      classList: { add: function () {}, remove: function () {}, toggle: function () {},
                   contains: function () { return false; } },
      getContext: function () { return null; },
      appendChild: function (c) { return c; },
      insertBefore: function (c) { return c; },
      removeChild: function (c) { return c; },
      remove: function () {},
      cloneNode: function () { return stubElement(tag); },
      setAttribute: function () {}, getAttribute: function () { return null; },
      removeAttribute: function () {}, hasAttribute: function () { return false; },
      addEventListener: function () {}, removeEventListener: function () {},
      querySelector: function () { return null; },
      querySelectorAll: function () { return []; },
      // Graphics._disableContextMenu walks document.body.getElementsByTagName('*').
      getElementsByTagName: function () { return []; },
      getElementsByClassName: function () { return []; },
      getBoundingClientRect: function () {
        return { left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 };
      },
      focus: function () {}, blur: function () {}, click: function () {},
    };
    return el;
  }
  var docHead = stubElement('head');
  var docBody = stubElement('body');
  // A FontFaceSet stand-in. When document.fonts is present MV takes its CSS
  // font-loading path (Graphics._cssFontLoading) and detects the game font via
  // fonts.check() instead of comparing measured text widths — which our
  // font-agnostic measureText can't distinguish, so Scene_Boot would otherwise
  // wait forever for the font and never advance to the title. Report the font
  // as ready so boot proceeds (we render text through the engine, not CSS).
  var fontFaceSet = {
    check: function () { return true; },
    load: function () { return Promise.resolve([]); },
    add: function () {}, delete: function () {}, clear: function () {},
    forEach: function () {}, size: 0, status: 'loaded',
  };
  fontFaceSet.ready = Promise.resolve(fontFaceSet);
  g.document = {
    createElement: function (tag) {
      tag = ('' + tag).toLowerCase();
      return tag === 'canvas' ? new Canvas() : stubElement(tag);
    },
    createTextNode: function () { return stubElement('#text'); },
    getElementById: function () { return null; },
    getElementsByTagName: function (tag) {
      tag = ('' + tag).toLowerCase();
      if (tag === 'head') return [docHead];
      if (tag === 'body') return [docBody];
      if (tag === 'script') {
        // Utils.canReadGameFiles reads the last <script>'s src over XHR to
        // verify local-file access; point it at a file that is always present
        // (rpg_core.js is a required MV marker) so the probe succeeds here.
        var sc = stubElement('script');
        sc.src = 'js/rpg_core.js';
        return [sc];
      }
      return [];
    },
    querySelector: function () { return null; },
    querySelectorAll: function () { return []; },
    createEvent: function () { return { initEvent: function () {} }; },
    addEventListener: function () {}, removeEventListener: function () {},
    body: docBody,
    documentElement: stubElement('html'),
    head: docHead,
    fonts: fontFaceSet,
  };

  // Image: MV's Bitmap loads PNGs with `new Image()` + `.src = url`. We decode
  // synchronously (stb_image, via __mv_imageLoad) into a canvas handle, but fire
  // onload/onerror on the next host frame (via requestAnimationFrame) to match
  // the browser contract MV's loader relies on — handlers are attached after src
  // is set, and MV polls ImageManager.isReady() across frames. rAF is used
  // rather than setTimeout so the deferral is independent of the host clock. The
  // decoded canvas handle is exposed as `__h`, so drawImage(image, ...) works
  // through the same srcHandle() path a canvas does.
  function ImageEl() {
    this.__h = 0;
    this.width = 0;
    this.height = 0;
    this.onload = null;
    this.onerror = null;
    this.complete = false;
    this._src = '';
  }
  Object.defineProperty(ImageEl.prototype, 'src', {
    get: function () { return this._src; },
    set: function (v) {
      var self = this;
      this._src = v;
      this.complete = false;
      var h = g.__mv_imageLoad(v);
      g.requestAnimationFrame(function () {
        if (h) {
          self.__h = h;
          self.width = g.__mv_canvasWidth(h);
          self.height = g.__mv_canvasHeight(h);
          self.complete = true;
          if (typeof self.onload === 'function') self.onload();
        } else if (typeof self.onerror === 'function') {
          self.onerror(new Error('image load failed: ' + v));
        }
      });
    },
  });
  ImageEl.prototype.addEventListener = function (type, cb) {
    if (type === 'load') this.onload = cb;
    else if (type === 'error') this.onerror = cb;
  };
  ImageEl.prototype.removeEventListener = function () {};
  g.Image = ImageEl;
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

// Expose a canvas's RGBA buffer to the on-screen present path (mvjs.cxx). At
// file scope but still able to reach the anonymous-namespace registry above.
const uint8_t* mv_canvas_pixels(int handle, int* w, int* h) {
  Canvas* c = canvas_get(handle);
  if (!c)
    return nullptr;
  if (w)
    *w = c->w;
  if (h)
    *h = c->h;
  return c->px.data();
}

void mv_install_canvas(JSContext* ctx) {
  JSValue global = JS_GetGlobalObject(ctx);
  install(ctx, global, "__mv_canvasCreate", js_create, 2);
  install(ctx, global, "__mv_canvasResize", js_resize, 3);
  install(ctx, global, "__mv_canvasWidth", js_width, 1);
  install(ctx, global, "__mv_canvasHeight", js_height, 1);
  install(ctx, global, "__mv_canvasFillRect", js_fill_rect, 9);
  install(ctx, global, "__mv_canvasClearRect", js_clear_rect, 5);
  install(ctx, global, "__mv_canvasDrawImage", js_draw_image, 17);
  install(ctx, global, "__mv_canvasGetPixel", js_get_pixel, 3);
  install(ctx, global, "__mv_imageLoad", js_image_load, 1);
  JS_FreeValue(ctx, global);

  JSValue r = JS_Eval(ctx, kCanvasPreamble, std::strlen(kCanvasPreamble),
                      "<mv-canvas-preamble>", JS_EVAL_TYPE_GLOBAL);
  JS_FreeValue(ctx, r);
}
