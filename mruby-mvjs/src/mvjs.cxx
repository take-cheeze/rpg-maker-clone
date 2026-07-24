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

}  // namespace

extern "C" void mrb_mruby_mvjs_gem_init(mrb_state* mrb) {
  RClass* mv = mrb_define_class(mrb, "MV", mrb->object_class);
  RClass* js = mrb_define_class_under(mrb, mv, "JS", mrb->object_class);
  mrb_define_class_method(mrb, js, "eval", js_eval, MRB_ARGS_REQ(1));
}

extern "C" void mrb_mruby_mvjs_gem_final(mrb_state* mrb) {}
