// The embedded JavaScript engine and host environment for RPG Maker MV support.
//
// This is the seam through which the rest of approach #2 (see
// docs/adr/0004-javascript-maker-mv-quickjs.md) plugs in: it embeds quickjs-ng
// and builds up the browser/host environment MV's own JavaScript expects.
//
//   M2: `MV::JS.eval` proves the engine runs.
//   M3: a *persistent* host (one runtime/context reused across evals) plus the
//       first host globals — console, the window/globalThis aliases, and a
//       synchronous XMLHttpRequest backed by a native file reader (how MV loads
//       its data/*.json). The event-loop pump and the Canvas2D -> Bitmap bridge
//       build on top of this in M3/M4.
//
// The mruby state is named `mrb` throughout because the exception-class macros
// (E_RUNTIME_ERROR, ...) expand to code that references a variable of that
// name. The JS host itself is independent of mruby (console/file IO go through
// C stdio), so it can live for the whole process.

#include <cstdio>
#include <cstring>
#include <string>

#include <mruby.h>
#include <mruby/string.h>

#include <quickjs.h>

namespace {

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
// ReferenceError when the file cannot be opened. This backs the XMLHttpRequest
// polyfill; MV resolves its data/asset paths relative to the game directory.
JSValue js_read_file(JSContext* ctx,
                     JSValueConst,
                     int argc,
                     JSValueConst* argv) {
  if (argc < 1)
    return JS_ThrowTypeError(ctx, "__mv_readFileSync: a path is required");
  const char* path = JS_ToCString(ctx, argv[0]);
  if (!path)
    return JS_EXCEPTION;
  std::FILE* f = std::fopen(path, "rb");
  if (!f) {
    JSValue err = JS_ThrowReferenceError(
        ctx, "__mv_readFileSync: cannot open '%s'", path);
    JS_FreeCString(ctx, path);
    return err;
  }
  JS_FreeCString(ctx, path);
  std::string data;
  char buf[4096];
  size_t n;
  while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0)
    data.append(buf, n);
  std::fclose(f);
  return JS_NewStringLen(ctx, data.data(), data.size());
}

// The host-global bootstrap, evaluated once when the context is created: the
// window/self/global aliases and a minimal synchronous XMLHttpRequest that
// reads local files through __mv_readFileSync. Kept close to the small surface
// MV's DataManager uses (open/setRequestHeader/send/onload/onerror/status/
// responseText).
const char* kHostPreamble = R"MVJS(
(function (g) {
  g.window = g;
  g.self = g;
  g.global = g;
  if (typeof g.globalThis === 'undefined') g.globalThis = g;

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

  // Passive host globals MV touches during boot.
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

  // Timers, requestAnimationFrame and the per-frame pump. The MV game drives
  // itself with requestAnimationFrame; the host owns the loop and advances this
  // queue once per frame from MV::JS.pump(nowMs), so the JS game shares the
  // engine's fixed cadence instead of blocking the process.
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
  JS_FreeValue(ctx, global);

  JSValue r = JS_Eval(ctx, kHostPreamble, std::strlen(kHostPreamble),
                      "<mv-host-preamble>", JS_EVAL_TYPE_GLOBAL);
  JS_FreeValue(ctx, r);
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

// MV::JS.eval(source) -> evaluate JavaScript in the persistent host context and
// return its (scalar) result. Raises RuntimeError on a JS exception. State
// (globals, defined vars) persists across calls, as the MV engine expects.
mrb_value js_eval(mrb_state* mrb, mrb_value self) {
  const char* src;
  mrb_int len;
  mrb_get_args(mrb, "s", &src, &len);

  JSContext* ctx = host();
  if (!ctx)
    mrb_raise(mrb, E_RUNTIME_ERROR, "MV::JS: failed to create the JS host");

  JSValue result = JS_Eval(ctx, src, static_cast<size_t>(len), "<eval>",
                           JS_EVAL_TYPE_GLOBAL);

  if (JS_IsException(result)) {
    JSValue exc = JS_GetException(ctx);
    const char* msg = JS_ToCString(ctx, exc);
    const std::string detail = std::string("MV::JS.eval failed: ") +
                               (msg ? msg : "JavaScript exception");
    if (msg)
      JS_FreeCString(ctx, msg);
    JS_FreeValue(ctx, exc);
    JS_FreeValue(ctx, result);
    mrb_raise(mrb, E_RUNTIME_ERROR, detail.c_str());
  }

  const mrb_value ret = js_to_mrb(mrb, ctx, result);
  JS_FreeValue(ctx, result);
  return ret;
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
  if (JS_IsException(r)) {
    JSValue exc = JS_GetException(ctx);
    const char* msg = JS_ToCString(ctx, exc);
    error = std::string("MV::JS.pump failed: ") +
            (msg ? msg : "JavaScript exception");
    if (msg)
      JS_FreeCString(ctx, msg);
    JS_FreeValue(ctx, exc);
  }
  JS_FreeValue(ctx, r);

  // Drain promise microtasks, unless a frame callback already errored.
  if (error.empty()) {
    JSContext* job_ctx;
    int status;
    while ((status = JS_ExecutePendingJob(g_rt, &job_ctx)) > 0) {
    }
    if (status < 0) {
      JSValue exc = JS_GetException(ctx);
      const char* msg = JS_ToCString(ctx, exc);
      error = std::string("MV::JS.pump job failed: ") +
              (msg ? msg : "JavaScript exception");
      if (msg)
        JS_FreeCString(ctx, msg);
      JS_FreeValue(ctx, exc);
    }
  }

  if (!error.empty())
    mrb_raise(mrb, E_RUNTIME_ERROR, error.c_str());
  return mrb_nil_value();
}

}  // namespace

extern "C" void mrb_mruby_mvjs_gem_init(mrb_state* mrb) {
  RClass* mv = mrb_define_class(mrb, "MV", mrb->object_class);
  RClass* js = mrb_define_class_under(mrb, mv, "JS", mrb->object_class);
  mrb_define_class_method(mrb, js, "eval", js_eval, MRB_ARGS_REQ(1));
  mrb_define_class_method(mrb, js, "pump", js_pump, MRB_ARGS_OPT(1));
}

extern "C" void mrb_mruby_mvjs_gem_final(mrb_state* mrb) {}
