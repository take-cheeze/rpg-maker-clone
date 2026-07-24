// The embedded JavaScript engine for RPG Maker MV support (milestone M2).
//
// This is the seam through which the rest of approach #2 (see
// docs/adr/0004-javascript-maker-mv-quickjs.md) plugs in: it embeds quickjs-ng
// and, for now, exposes a single entry point — `MV::JS.eval` — that proves the
// engine is built into the binary and can run JavaScript. The persistent game
// host (a reusable runtime, the browser/host globals and the Canvas2D -> Bitmap
// bridge) builds on top of this in later milestones.
//
// The mruby state is named `mrb` throughout because the exception-class macros
// (E_RUNTIME_ERROR, ...) expand to code that references a variable of that
// name.

#include <string>

#include <mruby.h>
#include <mruby/string.h>

#include <quickjs.h>

namespace {

// Convert a QuickJS scalar result into an mruby value. null/undefined become
// nil, booleans and numbers map directly, and everything else (objects,
// arrays, ...) is returned as its String coercion — M2 only needs to prove the
// engine runs; richer marshalling arrives with the host in M3.
mrb_value js_to_mrb(mrb_state* mrb, JSContext* ctx, JSValueConst v) {
  if (JS_IsNull(v) || JS_IsUndefined(v))
    return mrb_nil_value();
  if (JS_IsBool(v))
    return mrb_bool_value(JS_ToBool(ctx, v) != 0);
  if (JS_IsNumber(v)) {
    double d = 0;
    JS_ToFloat64(ctx, &d, v);
    // Return an Integer for integral values, a Float otherwise.
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

// MV::JS.eval(source) -> evaluate a snippet of JavaScript in a throwaway
// context and return its (scalar) result. Raises RuntimeError on a JS
// exception. A fresh runtime/context per call keeps this stateless and easy to
// test; the reusable game runtime lands with the host in M3.
mrb_value js_eval(mrb_state* mrb, mrb_value self) {
  const char* src;
  mrb_int len;
  mrb_get_args(mrb, "s", &src, &len);

  JSRuntime* rt = JS_NewRuntime();
  if (!rt)
    mrb_raise(mrb, E_RUNTIME_ERROR, "MV::JS.eval: failed to create JS runtime");
  JSContext* ctx = JS_NewContext(rt);
  if (!ctx) {
    JS_FreeRuntime(rt);
    mrb_raise(mrb, E_RUNTIME_ERROR, "MV::JS.eval: failed to create JS context");
  }

  JSValue result = JS_Eval(ctx, src, static_cast<size_t>(len), "<eval>",
                           JS_EVAL_TYPE_GLOBAL);

  if (JS_IsException(result)) {
    // Copy the exception message out before tearing the context down, then
    // raise with a plain C string (portable across mruby, no format
    // specifiers).
    JSValue exc = JS_GetException(ctx);
    const char* msg = JS_ToCString(ctx, exc);
    const std::string detail = std::string("MV::JS.eval failed: ") +
                               (msg ? msg : "JavaScript exception");
    if (msg)
      JS_FreeCString(ctx, msg);
    JS_FreeValue(ctx, exc);
    JS_FreeValue(ctx, result);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    mrb_raise(mrb, E_RUNTIME_ERROR, detail.c_str());
  }

  const mrb_value ret = js_to_mrb(mrb, ctx, result);
  JS_FreeValue(ctx, result);
  JS_FreeContext(ctx);
  JS_FreeRuntime(rt);
  return ret;
}

}  // namespace

extern "C" void mrb_mruby_mvjs_gem_init(mrb_state* mrb) {
  RClass* mv = mrb_define_class(mrb, "MV", mrb->object_class);
  RClass* js = mrb_define_class_under(mrb, mv, "JS", mrb->object_class);
  mrb_define_class_method(mrb, js, "eval", js_eval, MRB_ARGS_REQ(1));
}

extern "C" void mrb_mruby_mvjs_gem_final(mrb_state* mrb) {}
