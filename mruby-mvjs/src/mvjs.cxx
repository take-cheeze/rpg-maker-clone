// The embedded JavaScript engine and host environment for RPG Maker MV support.
//
// This is the seam through which the rest of approach #2 (see
// docs/adr/0004-javascript-maker-mv-quickjs.md) plugs in: it embeds quickjs-ng
// and builds up the browser/host environment MV's own JavaScript expects.
//
//   M2: `MV::JS.eval` proves the engine runs.
//   M3: a *persistent* host (one runtime/context reused across evals) plus the
//       browser/host globals MV boots against — console, the window/globalThis
//       aliases, a synchronous XMLHttpRequest (how MV loads data/*.json), the
//       timer/requestAnimationFrame event loop driven by `MV::JS.pump`, passive
//       navigator/location/localStorage, and the NW.js `require('fs'|'path')`
//       used for saves. `MV::JS.eval_file` loads a script file into the host.
//   M4: the Canvas2D -> mruby-rgss::Bitmap bridge (document/canvas/Image).
//
// The mruby state is named `mrb` throughout because the exception-class macros
// (E_RUNTIME_ERROR, ...) expand to code that references a variable of that
// name. The JS host itself is independent of mruby (console/file IO go through
// C stdio), so it can live for the whole process.

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>

#include <mruby.h>
#include <mruby/string.h>

#include <quickjs.h>

#include "mvhost.hxx"
#include "rgss_bitmap.hxx"

namespace {

// The game's base directory (see mv_resolve_path). Empty until Ruby sets it via
// `MV::JS.base_dir=` at boot; while empty, paths pass through untouched (so the
// host specs, which read fixtures by their own paths, are unaffected).
std::string g_base_dir;

// Read a whole file into `out`. Returns false if it cannot be opened.
bool read_file(const char* path, std::string& out) {
  std::FILE* f = std::fopen(path, "rb");
  if (!f)
    return false;
  char buf[4096];
  size_t n;
  while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0)
    out.append(buf, n);
  std::fclose(f);
  return true;
}

// -- native host functions ---------------------------------------------------

// console.log / warn / error / info: join the arguments with spaces and print.
JSValue js_console_log(JSContext* ctx,
                       JSValueConst,
                       int argc,
                       JSValueConst* argv) {
  std::string line;
  for (int i = 0; i < argc; ++i) {
    if (i)
      line += ' ';
    const char* s = JS_ToCString(ctx, argv[i]);
    if (s) {
      line += s;
      JS_FreeCString(ctx, s);
    }
  }
  std::fprintf(stdout, "%s\n", line.c_str());
  return JS_UNDEFINED;
}

// __mv_readFileSync(path) -> the file's contents as a string. Throws a
// ReferenceError when the file cannot be opened. Backs XMLHttpRequest and the
// require('fs') shim; MV resolves data/asset paths relative to the game dir.
JSValue js_read_file(JSContext* ctx,
                     JSValueConst,
                     int argc,
                     JSValueConst* argv) {
  if (argc < 1)
    return JS_ThrowTypeError(ctx, "__mv_readFileSync: a path is required");
  const char* path = JS_ToCString(ctx, argv[0]);
  if (!path)
    return JS_EXCEPTION;
  const std::string resolved = mv_resolve_path(path);
  JS_FreeCString(ctx, path);
  std::string data;
  if (!read_file(resolved.c_str(), data)) {
    return JS_ThrowReferenceError(ctx, "__mv_readFileSync: cannot open '%s'",
                                  resolved.c_str());
  }
  return JS_NewStringLen(ctx, data.data(), data.size());
}

// __mv_writeFileSync(path, data) -> write a string to a file (used by saves).
JSValue js_write_file(JSContext* ctx,
                      JSValueConst,
                      int argc,
                      JSValueConst* argv) {
  if (argc < 2)
    return JS_ThrowTypeError(ctx, "__mv_writeFileSync: path and data required");
  const char* path = JS_ToCString(ctx, argv[0]);
  if (!path)
    return JS_EXCEPTION;
  const std::string resolved = mv_resolve_path(path);
  JS_FreeCString(ctx, path);
  size_t dlen = 0;
  const char* data = JS_ToCStringLen(ctx, &dlen, argv[1]);
  if (!data)
    return JS_EXCEPTION;
  std::FILE* f = std::fopen(resolved.c_str(), "wb");
  if (!f) {
    JS_FreeCString(ctx, data);
    return JS_ThrowReferenceError(ctx, "__mv_writeFileSync: cannot write '%s'",
                                  resolved.c_str());
  }
  std::fwrite(data, 1, dlen, f);
  std::fclose(f);
  JS_FreeCString(ctx, data);
  return JS_UNDEFINED;
}

// __mv_existsSync(path) -> whether the path can be opened for reading.
JSValue js_file_exists(JSContext* ctx,
                       JSValueConst,
                       int argc,
                       JSValueConst* argv) {
  if (argc < 1)
    return JS_NewBool(ctx, 0);
  const char* path = JS_ToCString(ctx, argv[0]);
  if (!path)
    return JS_EXCEPTION;
  const std::string resolved = mv_resolve_path(path);
  JS_FreeCString(ctx, path);
  std::FILE* f = std::fopen(resolved.c_str(), "rb");
  const bool exists = f != nullptr;
  if (f)
    std::fclose(f);
  return JS_NewBool(ctx, exists);
}

// MV::JS.base_dir=(path) -> set the game root that game-relative asset paths
// (data/*.json, img/*.png, saves) are resolved against. Set once at boot.
mrb_value js_set_base_dir(mrb_state* mrb, mrb_value self) {
  const char* p;
  mrb_int len;
  mrb_get_args(mrb, "s", &p, &len);
  g_base_dir.assign(p, static_cast<size_t>(len));
  while (!g_base_dir.empty() && g_base_dir.back() == '/')
    g_base_dir.pop_back();
  return mrb_nil_value();
}

// The host-global bootstrap, evaluated once when the context is created. Kept
// close to the small surface MV's DataManager/StorageManager/SceneManager use.
const char* kHostPreamble = R"MVJS(
(function (g) {
  g.window = g;
  g.self = g;
  g.global = g;
  if (typeof g.globalThis === 'undefined') g.globalThis = g;

  // --- XMLHttpRequest (synchronous, local-file backed) ---------------------
  function XMLHttpRequest() {
    this.readyState = 0;
    this.status = 0;
    this.responseText = '';
    this.response = '';
    this.onload = null;
    this.onerror = null;
    this._path = '';
  }
  XMLHttpRequest.prototype.open = function (method, url) {
    this._path = url;
    this.readyState = 1;
  };
  XMLHttpRequest.prototype.setRequestHeader = function () {};
  XMLHttpRequest.prototype.overrideMimeType = function () {};
  XMLHttpRequest.prototype.send = function () {
    try {
      this.responseText = g.__mv_readFileSync(this._path);
      this.response = this.responseText;
      this.status = 200;
      this.readyState = 4;
      if (typeof this.onload === 'function') this.onload();
    } catch (e) {
      this.status = 404;
      this.readyState = 4;
      if (typeof this.onerror === 'function') this.onerror(e);
    }
  };
  g.XMLHttpRequest = XMLHttpRequest;

  // --- passive globals MV touches at boot ----------------------------------
  g.navigator = {
    userAgent: 'RPGMakerClone',
    language: 'en',
    platform: 'rpgmakerclone',
    appVersion: '',
  };
  g.location = {
    href: 'app://index.html',
    protocol: 'app:',
    search: '',
    hash: '',
    reload: function () {},
  };
  // Viewport metrics MV reads for its stretch scaling (Graphics._updateRealScale
  // divides by these); default to the classic MV screen size.
  g.innerWidth = 816;
  g.innerHeight = 624;
  g.devicePixelRatio = 1;
  (function () {
    var store = {};
    g.localStorage = {
      getItem: function (k) {
        return Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null;
      },
      setItem: function (k, v) { store[k] = String(v); },
      removeItem: function (k) { delete store[k]; },
      clear: function () { store = {}; },
      key: function (i) { return Object.keys(store)[i] || null; },
      get length() { return Object.keys(store).length; },
    };
  })();

  // --- NW.js style require('fs'|'path') for saves --------------------------
  // MV treats the presence of `require` as "running under NW.js" and switches
  // to local-file saves, which is exactly what we want.
  var modules = {
    fs: {
      readFileSync: function (path) { return g.__mv_readFileSync(path); },
      writeFileSync: function (path, data) {
        return g.__mv_writeFileSync(path, String(data));
      },
      existsSync: function (path) { return g.__mv_existsSync(path); },
      mkdirSync: function () {},
      unlinkSync: function () {},
    },
    path: {
      dirname: function (p) {
        var i = p.lastIndexOf('/');
        return i >= 0 ? p.slice(0, i) : '.';
      },
      basename: function (p) {
        var i = p.lastIndexOf('/');
        return i >= 0 ? p.slice(i + 1) : p;
      },
      extname: function (p) {
        var i = p.lastIndexOf('.');
        return i >= 0 ? p.slice(i) : '';
      },
      join: function () {
        return Array.prototype.slice.call(arguments).join('/');
      },
    },
  };
  g.require = function (name) {
    if (Object.prototype.hasOwnProperty.call(modules, name)) return modules[name];
    throw new Error('require: module not found: ' + name);
  };

  // --- timers, requestAnimationFrame and the per-frame pump ----------------
  // The MV game drives itself with requestAnimationFrame; the host owns the
  // loop and advances this queue once per frame from MV::JS.pump(nowMs), so the
  // JS game shares the engine's fixed cadence instead of blocking the process.
  var timers = [];
  var raf = [];
  var nextId = 1;
  var clock = 0;
  g.performance = {
    now: function () {
      return typeof Date !== 'undefined' && Date.now ? Date.now() : clock;
    },
  };
  g.setTimeout = function (cb, ms) {
    var id = nextId++;
    timers.push({ id: id, cb: cb, due: clock + (ms || 0), interval: 0 });
    return id;
  };
  g.setInterval = function (cb, ms) {
    var id = nextId++;
    timers.push({ id: id, cb: cb, due: clock + (ms || 0), interval: ms || 0 });
    return id;
  };
  g.clearTimeout = function (id) {
    timers = timers.filter(function (t) { return t.id !== id; });
  };
  g.clearInterval = g.clearTimeout;
  g.requestAnimationFrame = function (cb) {
    var id = nextId++;
    raf.push({ id: id, cb: cb });
    return id;
  };
  g.cancelAnimationFrame = function (id) {
    raf = raf.filter(function (r) { return r.id !== id; });
  };
  // Advance one frame: fire due timers (re-queuing intervals), then run the
  // animation-frame callbacks queued so far exactly once.
  g.__mv_runFrame = function (now) {
    clock = now || 0;
    var due = [];
    var keep = [];
    for (var i = 0; i < timers.length; i++) {
      if (timers[i].due <= clock) due.push(timers[i]);
      else keep.push(timers[i]);
    }
    timers = keep;
    for (var i = 0; i < due.length; i++) {
      var t = due[i];
      try { t.cb(); } catch (e) { if (g.console) console.error(e); }
      if (t.interval > 0) { t.due = clock + t.interval; timers.push(t); }
    }
    var frame = raf;
    raf = [];
    for (var i = 0; i < frame.length; i++) {
      try { frame[i].cb(clock); } catch (e) { if (g.console) console.error(e); }
    }
  };
})(this);
)MVJS";

// Install the native functions and evaluate the host preamble into a context.
void install_host_globals(JSContext* ctx) {
  JSValue global = JS_GetGlobalObject(ctx);

  JSValue console = JS_NewObject(ctx);
  JS_SetPropertyStr(ctx, console, "log",
                    JS_NewCFunction(ctx, js_console_log, "log", 1));
  JS_SetPropertyStr(ctx, console, "info",
                    JS_NewCFunction(ctx, js_console_log, "info", 1));
  JS_SetPropertyStr(ctx, console, "warn",
                    JS_NewCFunction(ctx, js_console_log, "warn", 1));
  JS_SetPropertyStr(ctx, console, "error",
                    JS_NewCFunction(ctx, js_console_log, "error", 1));
  JS_SetPropertyStr(ctx, global, "console", console);

  JS_SetPropertyStr(ctx, global, "__mv_readFileSync",
                    JS_NewCFunction(ctx, js_read_file, "__mv_readFileSync", 1));
  JS_SetPropertyStr(
      ctx, global, "__mv_writeFileSync",
      JS_NewCFunction(ctx, js_write_file, "__mv_writeFileSync", 2));
  JS_SetPropertyStr(ctx, global, "__mv_existsSync",
                    JS_NewCFunction(ctx, js_file_exists, "__mv_existsSync", 1));
  JS_FreeValue(ctx, global);

  JSValue r = JS_Eval(ctx, kHostPreamble, std::strlen(kHostPreamble),
                      "<mv-host-preamble>", JS_EVAL_TYPE_GLOBAL);
  JS_FreeValue(ctx, r);

  // The Canvas2D bridge (document/canvas/context), defined in mvcanvas.cxx.
  mv_install_canvas(ctx);
}

// -- the persistent host -----------------------------------------------------

// One JavaScript host per process: the MV game is single-threaded and one game
// runs at a time, so the runtime/context are created lazily and live for the
// process (freed at exit). Being independent of any mrb_state, the host is
// safe to share.
JSRuntime* g_rt = nullptr;
JSContext* g_ctx = nullptr;

JSContext* host() {
  if (!g_ctx) {
    g_rt = JS_NewRuntime();
    if (!g_rt)
      return nullptr;
    g_ctx = JS_NewContext(g_rt);
    if (!g_ctx) {
      JS_FreeRuntime(g_rt);
      g_rt = nullptr;
      return nullptr;
    }
    install_host_globals(g_ctx);
  }
  return g_ctx;
}

// Convert a QuickJS scalar result into an mruby value. null/undefined become
// nil, booleans and numbers map directly, and everything else (objects,
// arrays, ...) is returned as its String coercion — richer marshalling arrives
// as the host grows.
mrb_value js_to_mrb(mrb_state* mrb, JSContext* ctx, JSValueConst v) {
  if (JS_IsNull(v) || JS_IsUndefined(v))
    return mrb_nil_value();
  if (JS_IsBool(v))
    return mrb_bool_value(JS_ToBool(ctx, v) != 0);
  if (JS_IsNumber(v)) {
    double d = 0;
    JS_ToFloat64(ctx, &d, v);
    const mrb_int i = static_cast<mrb_int>(d);
    if (static_cast<double>(i) == d)
      return mrb_fixnum_value(i);
    return mrb_float_value(mrb, d);
  }
  const char* s = JS_ToCString(ctx, v);
  const mrb_value r = s ? mrb_str_new_cstr(mrb, s) : mrb_nil_value();
  if (s)
    JS_FreeCString(ctx, s);
  return r;
}

// Read the current JS exception as "message\n<stack>" (the stack pinpoints the
// file:line in the game's scripts, which is what makes iteration tractable).
std::string exception_detail(JSContext* ctx) {
  JSValue exc = JS_GetException(ctx);
  const char* msg = JS_ToCString(ctx, exc);
  std::string out = msg ? msg : "JavaScript exception";
  if (msg)
    JS_FreeCString(ctx, msg);
  JSValue stack = JS_GetPropertyStr(ctx, exc, "stack");
  if (!JS_IsUndefined(stack) && !JS_IsException(stack)) {
    const char* s = JS_ToCString(ctx, stack);
    if (s && *s) {
      out += '\n';
      out += s;
    }
    if (s)
      JS_FreeCString(ctx, s);
  }
  JS_FreeValue(ctx, stack);
  JS_FreeValue(ctx, exc);
  return out;
}

// Handle a JS_Eval/JS_Call result: raise RuntimeError (tagged with `what`) on a
// JS exception, otherwise marshal the value. Consumes `result`.
mrb_value complete_eval(mrb_state* mrb,
                        JSContext* ctx,
                        JSValue result,
                        const char* what) {
  if (JS_IsException(result)) {
    const std::string detail =
        std::string(what) + " failed: " + exception_detail(ctx);
    JS_FreeValue(ctx, result);
    mrb_raise(mrb, E_RUNTIME_ERROR, detail.c_str());
  }
  const mrb_value ret = js_to_mrb(mrb, ctx, result);
  JS_FreeValue(ctx, result);
  return ret;
}

// MV::JS.eval(source) -> evaluate JavaScript in the persistent host context and
// return its (scalar) result. State (globals, defined vars) persists across
// calls, as the MV engine expects.
mrb_value js_eval(mrb_state* mrb, mrb_value self) {
  const char* src;
  mrb_int len;
  mrb_get_args(mrb, "s", &src, &len);

  JSContext* ctx = host();
  if (!ctx)
    mrb_raise(mrb, E_RUNTIME_ERROR, "MV::JS: failed to create the JS host");

  JSValue result = JS_Eval(ctx, src, static_cast<size_t>(len), "<eval>",
                           JS_EVAL_TYPE_GLOBAL);
  return complete_eval(mrb, ctx, result, "MV::JS.eval");
}

// MV::JS.eval_file(path) -> read a script file and evaluate it in the host,
// using the path as the source name (so exceptions carry a useful location).
mrb_value js_eval_file(mrb_state* mrb, mrb_value self) {
  const char* path;
  mrb_int len;
  mrb_get_args(mrb, "s", &path, &len);
  const std::string p(path, len);

  std::string src;
  if (!read_file(p.c_str(), src))
    mrb_raise(
        mrb, E_RUNTIME_ERROR,
        (std::string("MV::JS.eval_file: cannot open '") + p + "'").c_str());

  JSContext* ctx = host();
  if (!ctx)
    mrb_raise(mrb, E_RUNTIME_ERROR, "MV::JS: failed to create the JS host");

  JSValue result =
      JS_Eval(ctx, src.data(), src.size(), p.c_str(), JS_EVAL_TYPE_GLOBAL);
  return complete_eval(mrb, ctx, result, "MV::JS.eval_file");
}

// MV::JS.pump(now_ms = 0) -> advance the host by one frame: fire due timers and
// the queued requestAnimationFrame callbacks (via __mv_runFrame), then drain
// the JS job queue (promise microtasks). Raises RuntimeError if a callback
// throws.
mrb_value js_pump(mrb_state* mrb, mrb_value self) {
  mrb_float now = 0;
  mrb_get_args(mrb, "|f", &now);

  JSContext* ctx = host();
  if (!ctx)
    mrb_raise(mrb, E_RUNTIME_ERROR, "MV::JS: failed to create the JS host");

  JSValue global = JS_GetGlobalObject(ctx);
  JSValue fn = JS_GetPropertyStr(ctx, global, "__mv_runFrame");
  JSValue arg = JS_NewFloat64(ctx, now);
  JSValue r = JS_Call(ctx, fn, global, 1, &arg);
  JS_FreeValue(ctx, arg);
  JS_FreeValue(ctx, fn);
  JS_FreeValue(ctx, global);

  std::string error;
  if (JS_IsException(r))
    error = "MV::JS.pump failed: " + exception_detail(ctx);
  JS_FreeValue(ctx, r);

  // Drain promise microtasks, unless a frame callback already errored.
  if (error.empty()) {
    JSContext* job_ctx;
    int status;
    while ((status = JS_ExecutePendingJob(g_rt, &job_ctx)) > 0) {
    }
    if (status < 0)
      error = "MV::JS.pump job failed: " + exception_detail(ctx);
  }

  if (!error.empty())
    mrb_raise(mrb, E_RUNTIME_ERROR, error.c_str());
  return mrb_nil_value();
}

// The handle of MV's on-screen canvas. PIXI's canvas renderer draws into its
// view (== Graphics._canvas); prefer the renderer's view and fall back to
// Graphics._canvas. Returns 0 before the renderer exists.
const char* kMainCanvasHandleExpr = R"MVJS(
(function () {
  try {
    if (typeof Graphics === 'undefined') return 0;
    var c = (Graphics._renderer && Graphics._renderer.view) || Graphics._canvas;
    return (c && c.__h) ? c.__h : 0;
  } catch (e) { return 0; }
})()
)MVJS";

// MV::JS.present(bitmap, handle = nil) -> copy the MV canvas onto `bitmap`.
// With no handle, the on-screen canvas (Graphics' view) is resolved from the
// running game; an explicit handle is used as-is (for tests). The canvas is
// RGBA and the Bitmap is LVGL ARGB8888 (B,G,R,A), so R/B are swapped during the
// copy, clamped to the overlapping region. Marks the Bitmap dirty so the next
// Graphics.update repaints it. Returns true if pixels were copied.
mrb_value js_present(mrb_state* mrb, mrb_value self) {
  mrb_value bmp;
  mrb_int handle = -1;
  mrb_get_args(mrb, "o|i", &bmp, &handle);

  int bw = 0, bh = 0;
  uint8_t* dst = rgss::bitmap_pixels(mrb, bmp, &bw, &bh);
  if (!dst)
    return mrb_false_value();

  JSContext* ctx = host();
  if (!ctx)
    return mrb_false_value();

  if (handle < 0) {
    JSValue r =
        JS_Eval(ctx, kMainCanvasHandleExpr, std::strlen(kMainCanvasHandleExpr),
                "<mv-present>", JS_EVAL_TYPE_GLOBAL);
    int32_t v = 0;
    if (!JS_IsException(r))
      JS_ToInt32(ctx, &v, r);
    JS_FreeValue(ctx, r);
    handle = v;
  }
  if (handle <= 0)
    return mrb_false_value();

  int cw = 0, ch = 0;
  const uint8_t* src = mv_canvas_pixels(static_cast<int>(handle), &cw, &ch);
  if (!src)
    return mrb_false_value();

  const int w = std::min(bw, cw);
  const int h = std::min(bh, ch);
  for (int y = 0; y < h; ++y) {
    const uint8_t* s = src + static_cast<size_t>(y) * cw * 4;
    uint8_t* d = dst + static_cast<size_t>(y) * bw * 4;
    for (int x = 0; x < w; ++x) {
      d[0] = s[2];  // B
      d[1] = s[1];  // G
      d[2] = s[0];  // R
      d[3] = s[3];  // A
      s += 4;
      d += 4;
    }
  }
  rgss::bitmap_mark_dirty(mrb, bmp);
  return mrb_true_value();
}

}  // namespace

// Root a game-relative path at the configured base dir. Declared in mvhost.hxx
// and shared with the Canvas2D image loader (mvcanvas.cxx). Kept at file scope
// (external linkage) so it can reach the anonymous-namespace `g_base_dir`.
std::string mv_resolve_path(const std::string& p) {
  if (p.empty() || p[0] == '/' || g_base_dir.empty())
    return p;
  // Already rooted at the base dir (e.g. a path the Ruby side pre-joined)?
  if (p.size() > g_base_dir.size() &&
      p.compare(0, g_base_dir.size(), g_base_dir) == 0 &&
      p[g_base_dir.size()] == '/')
    return p;
  return g_base_dir + "/" + p;
}

extern "C" void mrb_mruby_mvjs_gem_init(mrb_state* mrb) {
  RClass* mv = mrb_define_class(mrb, "MV", mrb->object_class);
  RClass* js = mrb_define_class_under(mrb, mv, "JS", mrb->object_class);
  mrb_define_class_method(mrb, js, "eval", js_eval, MRB_ARGS_REQ(1));
  mrb_define_class_method(mrb, js, "eval_file", js_eval_file, MRB_ARGS_REQ(1));
  mrb_define_class_method(mrb, js, "pump", js_pump, MRB_ARGS_OPT(1));
  mrb_define_class_method(mrb, js, "base_dir=", js_set_base_dir,
                          MRB_ARGS_REQ(1));
  mrb_define_class_method(mrb, js, "present", js_present, MRB_ARGS_ARG(1, 1));
}

extern "C" void mrb_mruby_mvjs_gem_final(mrb_state* mrb) {}
