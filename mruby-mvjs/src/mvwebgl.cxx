// WebGLRenderingContext bridge for the JavaScript makers' MZ path (milestone
// M6.3b). RPG Maker MZ ships PIXI v5, which is WebGL-only, so
// `SceneManager.run` aborts at `Utils.canUseWebGL()` unless
// `canvas.getContext("webgl")` returns a real context. This wraps the native
// surfaceless-EGL GLES2 backend (mvgl.cxx / mvgl.hxx) as the WebGL API surface
// PIXI drives.
//
// The binding idiom matches the Canvas2D bridge (mvcanvas.cxx): opaque integer
// handles into a native registry, flat `__mv_gl*` global C functions, and a JS
// prototype (`WebGLRenderingContext`, in kWebGLPreamble) that marshals into
// them. WebGL API objects (WebGLShader/Program/Buffer/Texture/Framebuffer and
// uniform locations) are represented directly by their GL integer names, which
// PIXI only ever stores and passes back — a deliberate simplification of the
// full spec objects.
//
// Scope: M6.3b lands the wrapper (real context, the WebGL1 method + enum
// surface, native-backed calls) so getContext returns non-null and
// canUseWebGL() passes. The PIXI-specific long tail found by actually booting a
// frame (texture Y-flip, VAO extension, the full parameter table) is M6.3c.

#include "mvgl.hxx"
#include "mvhost.hxx"

// GLES2 is only reachable where the EGL backend compiled in (see mvgl.cxx). On
// Emscripten (browser WebGL) and header-less builds (e.g. darwin) this whole
// bridge collapses to a no-op install, and the canvas shim keeps returning null
// for getContext("webgl") because the `__mv_gl*` natives are never registered.
#if !defined(__EMSCRIPTEN__) && __has_include(<EGL/egl.h>) && \
    __has_include(<GLES2/gl2.h>)
#define MVJS_HAVE_WEBGL 1

#include <EGL/egl.h>
#include <GLES2/gl2.h>

#include <cstring>
#include <vector>

// GLES2 has no packed depth/stencil renderbuffer format in its base header; the
// value is the one OES_packed_depth_stencil defines, which mvgl.cxx already
// uses for the main FBO's own attachment.
#ifndef GL_DEPTH24_STENCIL8
#define GL_DEPTH24_STENCIL8 0x88F0
#endif
// WebGL1-only enums, absent from GLES2: a combined internal format and a
// combined attachment point. Both are translated below (see
// js_gl_*renderbuffer*).
#ifndef GL_DEPTH_STENCIL
#define GL_DEPTH_STENCIL 0x84F9
#endif
#ifndef GL_DEPTH_STENCIL_ATTACHMENT
#define GL_DEPTH_STENCIL_ATTACHMENT 0x821A
#endif

namespace {

// The GL contexts backing live WebGLRenderingContext objects, referenced from
// JS by integer handle (index + 1; 0 is the null handle), mirroring g_canvases.
std::vector<mvgl::Context*> g_gl;

// UNPACK_PREMULTIPLY_ALPHA_WEBGL's current value per context (see
// js_gl_pixel_storei and premultiply_rgba below) -- WebGL pixel-store state
// with no real GL equivalent to hold it in, so it is tracked here instead.
// Parallel to g_gl (same handle, grown in lockstep in js_gl_create).
std::vector<bool> g_premultiply;

// UNPACK_FLIP_Y_WEBGL's current value per context, the same shape as
// g_premultiply just above (see js_gl_pixel_storei and flip_y_rgba below).
std::vector<bool> g_flip_y;

// Handle -> context, making it (and its FBO) current on the calling thread.
// Tracks the last-bound handle so the common single-context case skips the
// redundant eglMakeCurrent. Returns nullptr for an unknown handle.
int g_current = 0;
mvgl::Context* bind(int handle) {
  if (handle < 1 || static_cast<size_t>(handle) > g_gl.size())
    return nullptr;
  mvgl::Context* c = g_gl[static_cast<size_t>(handle) - 1];
  if (c && g_current != handle) {
    mvgl::make_current(c);
    g_current = handle;
  }
  return c;
}

int gi(JSContext* ctx, int argc, JSValueConst* argv, int i) {
  int32_t v = 0;
  if (i < argc)
    JS_ToInt32(ctx, &v, argv[i]);
  return v;
}

double gd(JSContext* ctx, int argc, JSValueConst* argv, int i) {
  double v = 0;
  if (i < argc)
    JS_ToFloat64(ctx, &v, argv[i]);
  return v;
}

// A numeric JS array (or TypedArray) as doubles, via .length + indexing. Used
// for the uniform*fv / uniformMatrix*fv float paths, where element type is
// known from the call.
std::vector<double> num_array(JSContext* ctx, JSValueConst v) {
  std::vector<double> out;
  JSValue lenv = JS_GetPropertyStr(ctx, v, "length");
  int64_t len = 0;
  JS_ToInt64(ctx, &len, lenv);
  JS_FreeValue(ctx, lenv);
  for (int64_t i = 0; i < len; ++i) {
    JSValue e = JS_GetPropertyUint32(ctx, v, static_cast<uint32_t>(i));
    double d = 0;
    JS_ToFloat64(ctx, &d, e);
    JS_FreeValue(ctx, e);
    out.push_back(d);
  }
  return out;
}

// Raw bytes of a WebGL `BufferSource`, for bufferData / texImage2D /
// readPixels where the byte layout (Float32, Uint16, ...) must be preserved
// rather than coerced through double. `*hold` keeps the backing ArrayBuffer
// alive; the caller frees it after the GL call. Returns nullptr for anything
// that is neither a view nor a buffer.
//
// **A bare `ArrayBuffer` counts.** WebGL's `BufferSource` is
// `ArrayBufferView | ArrayBuffer`, and PIXI v5 uploads the sprite batcher's
// whole vertex block as the raw `ArrayBuffer` behind its interleaved views
// (`ViewableBuffer.rawBinaryData`). Handling only views made that upload
// silently zero-length, so every batched sprite drew from an empty vertex
// buffer — degenerate triangles, no fragments — which is why MZ rendered its
// tilemap (a separate rmmz renderer with its own geometry) and nothing else:
// no characters, no windows, no text.
uint8_t* view_bytes(JSContext* ctx,
                    JSValueConst v,
                    size_t* out_len,
                    JSValue* hold) {
  size_t off = 0, len = 0, bpe = 0;
  JSValue ab = JS_GetTypedArrayBuffer(ctx, v, &off, &len, &bpe);
  if (JS_IsException(ab)) {
    JS_FreeValue(ctx, ab);
    // Not a view. Clear the TypeError it set so it cannot contaminate the next
    // eval, then try the value itself as an ArrayBuffer.
    JS_FreeValue(ctx, JS_GetException(ctx));
    size_t raw = 0;
    uint8_t* p = JS_GetArrayBuffer(ctx, &raw, v);
    if (!p) {
      // Neither view nor buffer (e.g. null): clear again and report nothing.
      JS_FreeValue(ctx, JS_GetException(ctx));
      *hold = JS_UNDEFINED;
      *out_len = 0;
      return nullptr;
    }
    // JS_GetArrayBuffer borrows; the caller frees `*hold`, so dup to keep the
    // buffer alive across the GL call exactly as the view path does.
    *hold = JS_DupValue(ctx, v);
    *out_len = raw;
    return p;
  }
  size_t sz = 0;
  uint8_t* p = JS_GetArrayBuffer(ctx, &sz, ab);
  *hold = ab;
  *out_len = len;
  return p ? p + off : nullptr;
}

// -- context lifecycle -------------------------------------------------------

// __mv_glCreate(w, h) -> handle (0 on failure)
JSValue js_gl_create(JSContext* ctx,
                     JSValueConst,
                     int argc,
                     JSValueConst* argv) {
  mvgl::Context* c =
      mvgl::create(gi(ctx, argc, argv, 0), gi(ctx, argc, argv, 1));
  if (!c)
    return JS_NewInt32(ctx, 0);
  g_gl.push_back(c);
  g_premultiply.push_back(false);
  g_flip_y.push_back(false);
  g_current = static_cast<int>(g_gl.size());
  return JS_NewInt32(ctx, g_current);
}

// __mv_glResize(handle, w, h) -> bool: re-specify the context's render target.
// The game's canvas is still 0x0 when `getContext("webgl")` first runs (clamped
// to 1x1 by the shim), and MZ only sizes it later, in Scene_Boot.resizeScreen
// -> Graphics.resize; without following that, everything renders into a 1x1
// target and both the present and the screenshot read back a single pixel.
JSValue js_gl_resize(JSContext* ctx,
                     JSValueConst,
                     int argc,
                     JSValueConst* argv) {
  mvgl::Context* c = bind(gi(ctx, argc, argv, 0));
  if (!c)
    return JS_NewBool(ctx, 0);
  return JS_NewBool(
      ctx, mvgl::resize(c, gi(ctx, argc, argv, 1), gi(ctx, argc, argv, 2)));
}

// -- whole-context state -----------------------------------------------------

JSValue js_gl_viewport(JSContext* ctx,
                       JSValueConst,
                       int argc,
                       JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glViewport(gi(ctx, argc, argv, 1), gi(ctx, argc, argv, 2),
               gi(ctx, argc, argv, 3), gi(ctx, argc, argv, 4));
  return JS_UNDEFINED;
}

JSValue js_gl_scissor(JSContext* ctx,
                      JSValueConst,
                      int argc,
                      JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glScissor(gi(ctx, argc, argv, 1), gi(ctx, argc, argv, 2),
              gi(ctx, argc, argv, 3), gi(ctx, argc, argv, 4));
  return JS_UNDEFINED;
}

JSValue js_gl_clear_color(JSContext* ctx,
                          JSValueConst,
                          int argc,
                          JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glClearColor(static_cast<GLclampf>(gd(ctx, argc, argv, 1)),
                 static_cast<GLclampf>(gd(ctx, argc, argv, 2)),
                 static_cast<GLclampf>(gd(ctx, argc, argv, 3)),
                 static_cast<GLclampf>(gd(ctx, argc, argv, 4)));
  return JS_UNDEFINED;
}

JSValue js_gl_clear(JSContext* ctx,
                    JSValueConst,
                    int argc,
                    JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glClear(static_cast<GLbitfield>(gi(ctx, argc, argv, 1)));
  return JS_UNDEFINED;
}

JSValue js_gl_enable(JSContext* ctx,
                     JSValueConst,
                     int argc,
                     JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glEnable(static_cast<GLenum>(gi(ctx, argc, argv, 1)));
  return JS_UNDEFINED;
}

JSValue js_gl_disable(JSContext* ctx,
                      JSValueConst,
                      int argc,
                      JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glDisable(static_cast<GLenum>(gi(ctx, argc, argv, 1)));
  return JS_UNDEFINED;
}

JSValue js_gl_blend_func(JSContext* ctx,
                         JSValueConst,
                         int argc,
                         JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glBlendFunc(static_cast<GLenum>(gi(ctx, argc, argv, 1)),
                static_cast<GLenum>(gi(ctx, argc, argv, 2)));
  return JS_UNDEFINED;
}

JSValue js_gl_blend_func_separate(JSContext* ctx,
                                  JSValueConst,
                                  int argc,
                                  JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glBlendFuncSeparate(static_cast<GLenum>(gi(ctx, argc, argv, 1)),
                        static_cast<GLenum>(gi(ctx, argc, argv, 2)),
                        static_cast<GLenum>(gi(ctx, argc, argv, 3)),
                        static_cast<GLenum>(gi(ctx, argc, argv, 4)));
  return JS_UNDEFINED;
}

// Stencil state. MZ's WindowLayer masks each window to its own shape with it:
// draw the window with the test set to "pass where the buffer is 0", then draw
// the window's shape with REPLACE to mark those texels as 1, so the *next*
// window in the layer cannot paint over the one in front of it.
JSValue js_gl_stencil_func(JSContext* ctx,
                           JSValueConst,
                           int argc,
                           JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glStencilFunc(static_cast<GLenum>(gi(ctx, argc, argv, 1)),
                  static_cast<GLint>(gi(ctx, argc, argv, 2)),
                  static_cast<GLuint>(gi(ctx, argc, argv, 3)));
  return JS_UNDEFINED;
}

JSValue js_gl_stencil_op(JSContext* ctx,
                         JSValueConst,
                         int argc,
                         JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glStencilOp(static_cast<GLenum>(gi(ctx, argc, argv, 1)),
                static_cast<GLenum>(gi(ctx, argc, argv, 2)),
                static_cast<GLenum>(gi(ctx, argc, argv, 3)));
  return JS_UNDEFINED;
}

JSValue js_gl_stencil_mask(JSContext* ctx,
                           JSValueConst,
                           int argc,
                           JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glStencilMask(static_cast<GLuint>(gi(ctx, argc, argv, 1)));
  return JS_UNDEFINED;
}

JSValue js_gl_clear_stencil(JSContext* ctx,
                            JSValueConst,
                            int argc,
                            JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glClearStencil(static_cast<GLint>(gi(ctx, argc, argv, 1)));
  return JS_UNDEFINED;
}

JSValue js_gl_blend_equation(JSContext* ctx,
                             JSValueConst,
                             int argc,
                             JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glBlendEquation(static_cast<GLenum>(gi(ctx, argc, argv, 1)));
  return JS_UNDEFINED;
}

JSValue js_gl_blend_equation_separate(JSContext* ctx,
                                      JSValueConst,
                                      int argc,
                                      JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glBlendEquationSeparate(static_cast<GLenum>(gi(ctx, argc, argv, 1)),
                            static_cast<GLenum>(gi(ctx, argc, argv, 2)));
  return JS_UNDEFINED;
}

JSValue js_gl_depth_func(JSContext* ctx,
                         JSValueConst,
                         int argc,
                         JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glDepthFunc(static_cast<GLenum>(gi(ctx, argc, argv, 1)));
  return JS_UNDEFINED;
}

JSValue js_gl_depth_mask(JSContext* ctx,
                         JSValueConst,
                         int argc,
                         JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glDepthMask(gi(ctx, argc, argv, 1) ? GL_TRUE : GL_FALSE);
  return JS_UNDEFINED;
}

JSValue js_gl_color_mask(JSContext* ctx,
                         JSValueConst,
                         int argc,
                         JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glColorMask(gi(ctx, argc, argv, 1) ? GL_TRUE : GL_FALSE,
                gi(ctx, argc, argv, 2) ? GL_TRUE : GL_FALSE,
                gi(ctx, argc, argv, 3) ? GL_TRUE : GL_FALSE,
                gi(ctx, argc, argv, 4) ? GL_TRUE : GL_FALSE);
  return JS_UNDEFINED;
}

JSValue js_gl_cull_face(JSContext* ctx,
                        JSValueConst,
                        int argc,
                        JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glCullFace(static_cast<GLenum>(gi(ctx, argc, argv, 1)));
  return JS_UNDEFINED;
}

JSValue js_gl_front_face(JSContext* ctx,
                         JSValueConst,
                         int argc,
                         JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glFrontFace(static_cast<GLenum>(gi(ctx, argc, argv, 1)));
  return JS_UNDEFINED;
}

// WebGL's own UNPACK_FLIP_Y_WEBGL/UNPACK_PREMULTIPLY_ALPHA_WEBGL enum values
// (see kWebGLPreamble's `K`); neither has a real GL equivalent, so both are
// tracked below instead of forwarded.
constexpr GLenum kUnpackFlipYWebGL = 0x9240;
constexpr GLenum kUnpackPremultiplyAlphaWebGL = 0x9241;

// WebGL's own UNPACK_* pixel-store parameters (FLIP_Y, PREMULTIPLY_ALPHA,
// COLORSPACE_CONVERSION; 0x9240..0x9245) are not real GL enums and would
// raise GL_INVALID_ENUM if forwarded, so real ones (UNPACK/PACK_ALIGNMENT)
// aside, this only swallows the rest -- except FLIP_Y and PREMULTIPLY_ALPHA,
// each honoured by transforming pixels before the real upload call (see
// flip_y_rgba/premultiply_rgba and their callers). PREMULTIPLY_ALPHA is the
// one that matters for a stock PIXI v5 build (BaseTexture's default alphaMode
// premultiplies on upload); FLIP_Y is tracked and genuinely applied the same
// way, but as of this writing no real content this project has driven
// through the engine (including a full played-out battle against a real
// downloaded MZ release, data/EgoicAnswers -- see docs/TODO.md's M6.3c) has
// ever been observed setting it `true` rather than resetting it to the
// already-default `false` -- see gl_test.rb's own pixel-level coverage for
// proof this path works regardless of whether real content has reached it
// yet.
JSValue js_gl_pixel_storei(JSContext* ctx,
                           JSValueConst,
                           int argc,
                           JSValueConst* argv) {
  const GLenum pname = static_cast<GLenum>(gi(ctx, argc, argv, 1));
  if (pname == kUnpackFlipYWebGL) {
    const int handle = gi(ctx, argc, argv, 0);
    if (handle >= 1 && static_cast<size_t>(handle) <= g_flip_y.size())
      g_flip_y[static_cast<size_t>(handle) - 1] = gi(ctx, argc, argv, 2) != 0;
    return JS_UNDEFINED;
  }
  if (pname == kUnpackPremultiplyAlphaWebGL) {
    const int handle = gi(ctx, argc, argv, 0);
    if (handle >= 1 && static_cast<size_t>(handle) <= g_premultiply.size())
      g_premultiply[static_cast<size_t>(handle) - 1] =
          gi(ctx, argc, argv, 2) != 0;
    return JS_UNDEFINED;
  }
  if (pname >= 0x9240 && pname <= 0x9245)
    return JS_UNDEFINED;
  if (bind(gi(ctx, argc, argv, 0)))
    glPixelStorei(pname, gi(ctx, argc, argv, 2));
  return JS_UNDEFINED;
}

JSValue js_gl_active_texture(JSContext* ctx,
                             JSValueConst,
                             int argc,
                             JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glActiveTexture(static_cast<GLenum>(gi(ctx, argc, argv, 1)));
  return JS_UNDEFINED;
}

// -- shaders & programs ------------------------------------------------------

JSValue js_gl_create_shader(JSContext* ctx,
                            JSValueConst,
                            int argc,
                            JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_NewInt32(ctx, 0);
  return JS_NewInt32(ctx, static_cast<int32_t>(glCreateShader(
                              static_cast<GLenum>(gi(ctx, argc, argv, 1)))));
}

JSValue js_gl_shader_source(JSContext* ctx,
                            JSValueConst,
                            int argc,
                            JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_UNDEFINED;
  const char* src = argc > 2 ? JS_ToCString(ctx, argv[2]) : nullptr;
  if (src) {
    glShaderSource(static_cast<GLuint>(gi(ctx, argc, argv, 1)), 1, &src,
                   nullptr);
    JS_FreeCString(ctx, src);
  }
  return JS_UNDEFINED;
}

JSValue js_gl_compile_shader(JSContext* ctx,
                             JSValueConst,
                             int argc,
                             JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glCompileShader(static_cast<GLuint>(gi(ctx, argc, argv, 1)));
  return JS_UNDEFINED;
}

JSValue js_gl_get_shader_parameter(JSContext* ctx,
                                   JSValueConst,
                                   int argc,
                                   JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_NULL;
  GLint out = 0;
  glGetShaderiv(static_cast<GLuint>(gi(ctx, argc, argv, 1)),
                static_cast<GLenum>(gi(ctx, argc, argv, 2)), &out);
  return JS_NewInt32(ctx, out);
}

JSValue js_gl_get_shader_info_log(JSContext* ctx,
                                  JSValueConst,
                                  int argc,
                                  JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_NewString(ctx, "");
  char log[2048];
  GLsizei n = 0;
  glGetShaderInfoLog(static_cast<GLuint>(gi(ctx, argc, argv, 1)), sizeof(log),
                     &n, log);
  return JS_NewStringLen(ctx, log, static_cast<size_t>(n));
}

JSValue js_gl_delete_shader(JSContext* ctx,
                            JSValueConst,
                            int argc,
                            JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glDeleteShader(static_cast<GLuint>(gi(ctx, argc, argv, 1)));
  return JS_UNDEFINED;
}

JSValue js_gl_create_program(JSContext* ctx,
                             JSValueConst,
                             int argc,
                             JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_NewInt32(ctx, 0);
  return JS_NewInt32(ctx, static_cast<int32_t>(glCreateProgram()));
}

JSValue js_gl_attach_shader(JSContext* ctx,
                            JSValueConst,
                            int argc,
                            JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glAttachShader(static_cast<GLuint>(gi(ctx, argc, argv, 1)),
                   static_cast<GLuint>(gi(ctx, argc, argv, 2)));
  return JS_UNDEFINED;
}

JSValue js_gl_bind_attrib_location(JSContext* ctx,
                                   JSValueConst,
                                   int argc,
                                   JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_UNDEFINED;
  const char* name = argc > 3 ? JS_ToCString(ctx, argv[3]) : nullptr;
  if (name) {
    glBindAttribLocation(static_cast<GLuint>(gi(ctx, argc, argv, 1)),
                         static_cast<GLuint>(gi(ctx, argc, argv, 2)), name);
    JS_FreeCString(ctx, name);
  }
  return JS_UNDEFINED;
}

JSValue js_gl_link_program(JSContext* ctx,
                           JSValueConst,
                           int argc,
                           JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glLinkProgram(static_cast<GLuint>(gi(ctx, argc, argv, 1)));
  return JS_UNDEFINED;
}

JSValue js_gl_get_program_parameter(JSContext* ctx,
                                    JSValueConst,
                                    int argc,
                                    JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_NULL;
  GLint out = 0;
  glGetProgramiv(static_cast<GLuint>(gi(ctx, argc, argv, 1)),
                 static_cast<GLenum>(gi(ctx, argc, argv, 2)), &out);
  return JS_NewInt32(ctx, out);
}

JSValue js_gl_get_program_info_log(JSContext* ctx,
                                   JSValueConst,
                                   int argc,
                                   JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_NewString(ctx, "");
  char log[2048];
  GLsizei n = 0;
  glGetProgramInfoLog(static_cast<GLuint>(gi(ctx, argc, argv, 1)), sizeof(log),
                      &n, log);
  return JS_NewStringLen(ctx, log, static_cast<size_t>(n));
}

JSValue js_gl_use_program(JSContext* ctx,
                          JSValueConst,
                          int argc,
                          JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glUseProgram(static_cast<GLuint>(gi(ctx, argc, argv, 1)));
  return JS_UNDEFINED;
}

JSValue js_gl_delete_program(JSContext* ctx,
                             JSValueConst,
                             int argc,
                             JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glDeleteProgram(static_cast<GLuint>(gi(ctx, argc, argv, 1)));
  return JS_UNDEFINED;
}

JSValue js_gl_get_attrib_location(JSContext* ctx,
                                  JSValueConst,
                                  int argc,
                                  JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_NewInt32(ctx, -1);
  const char* name = argc > 2 ? JS_ToCString(ctx, argv[2]) : nullptr;
  GLint loc = -1;
  if (name) {
    loc =
        glGetAttribLocation(static_cast<GLuint>(gi(ctx, argc, argv, 1)), name);
    JS_FreeCString(ctx, name);
  }
  return JS_NewInt32(ctx, loc);
}

// -1 (not found) -> null in the JS wrapper, matching getUniformLocation's spec.
JSValue js_gl_get_uniform_location(JSContext* ctx,
                                   JSValueConst,
                                   int argc,
                                   JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_NewInt32(ctx, -1);
  const char* name = argc > 2 ? JS_ToCString(ctx, argv[2]) : nullptr;
  GLint loc = -1;
  if (name) {
    loc =
        glGetUniformLocation(static_cast<GLuint>(gi(ctx, argc, argv, 1)), name);
    JS_FreeCString(ctx, name);
  }
  return JS_NewInt32(ctx, loc);
}

// getActiveUniform/getActiveAttrib -> { size, type, name } (WebGLActiveInfo).
// PIXI's shader system uses these to build its uniform/attribute maps.
JSValue active_info(JSContext* ctx,
                    bool uniform,
                    int argc,
                    JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_NULL;
  const GLuint prog = static_cast<GLuint>(gi(ctx, argc, argv, 1));
  const GLuint index = static_cast<GLuint>(gi(ctx, argc, argv, 2));
  char name[256];
  GLsizei len = 0;
  GLint size = 0;
  GLenum type = 0;
  if (uniform)
    glGetActiveUniform(prog, index, sizeof(name), &len, &size, &type, name);
  else
    glGetActiveAttrib(prog, index, sizeof(name), &len, &size, &type, name);
  JSValue o = JS_NewObject(ctx);
  JS_SetPropertyStr(ctx, o, "size", JS_NewInt32(ctx, size));
  JS_SetPropertyStr(ctx, o, "type",
                    JS_NewInt32(ctx, static_cast<int32_t>(type)));
  JS_SetPropertyStr(ctx, o, "name",
                    JS_NewStringLen(ctx, name, static_cast<size_t>(len)));
  return o;
}
JSValue js_gl_get_active_uniform(JSContext* ctx,
                                 JSValueConst,
                                 int argc,
                                 JSValueConst* argv) {
  return active_info(ctx, true, argc, argv);
}
JSValue js_gl_get_active_attrib(JSContext* ctx,
                                JSValueConst,
                                int argc,
                                JSValueConst* argv) {
  return active_info(ctx, false, argc, argv);
}

// -- buffers & vertex attributes ---------------------------------------------

JSValue js_gl_create_buffer(JSContext* ctx,
                            JSValueConst,
                            int argc,
                            JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_NewInt32(ctx, 0);
  GLuint b = 0;
  glGenBuffers(1, &b);
  return JS_NewInt32(ctx, static_cast<int32_t>(b));
}

JSValue js_gl_bind_buffer(JSContext* ctx,
                          JSValueConst,
                          int argc,
                          JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glBindBuffer(static_cast<GLenum>(gi(ctx, argc, argv, 1)),
                 static_cast<GLuint>(gi(ctx, argc, argv, 2)));
  return JS_UNDEFINED;
}

// bufferData(target, ArrayBufferView|size, usage). A number allocates an
// uninitialised store; a view uploads its raw bytes (type preserved).
JSValue js_gl_buffer_data(JSContext* ctx,
                          JSValueConst,
                          int argc,
                          JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_UNDEFINED;
  const GLenum target = static_cast<GLenum>(gi(ctx, argc, argv, 1));
  const GLenum usage = static_cast<GLenum>(gi(ctx, argc, argv, 3));
  if (argc > 2 && JS_IsNumber(argv[2])) {
    int64_t sz = 0;
    JS_ToInt64(ctx, &sz, argv[2]);
    glBufferData(target, static_cast<GLsizeiptr>(sz), nullptr, usage);
  } else if (argc > 2) {
    JSValue hold;
    size_t len = 0;
    uint8_t* p = view_bytes(ctx, argv[2], &len, &hold);
    glBufferData(target, static_cast<GLsizeiptr>(len), p, usage);
    JS_FreeValue(ctx, hold);
  }
  return JS_UNDEFINED;
}

// bufferSubData(target, offset, ArrayBufferView)
JSValue js_gl_buffer_sub_data(JSContext* ctx,
                              JSValueConst,
                              int argc,
                              JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_UNDEFINED;
  if (argc > 3) {
    JSValue hold;
    size_t len = 0;
    uint8_t* p = view_bytes(ctx, argv[3], &len, &hold);
    if (p)
      glBufferSubData(static_cast<GLenum>(gi(ctx, argc, argv, 1)),
                      static_cast<GLintptr>(gi(ctx, argc, argv, 2)),
                      static_cast<GLsizeiptr>(len), p);
    JS_FreeValue(ctx, hold);
  }
  return JS_UNDEFINED;
}

JSValue js_gl_delete_buffer(JSContext* ctx,
                            JSValueConst,
                            int argc,
                            JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0))) {
    GLuint b = static_cast<GLuint>(gi(ctx, argc, argv, 1));
    glDeleteBuffers(1, &b);
  }
  return JS_UNDEFINED;
}

JSValue js_gl_enable_vertex_attrib_array(JSContext* ctx,
                                         JSValueConst,
                                         int argc,
                                         JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glEnableVertexAttribArray(static_cast<GLuint>(gi(ctx, argc, argv, 1)));
  return JS_UNDEFINED;
}

JSValue js_gl_disable_vertex_attrib_array(JSContext* ctx,
                                          JSValueConst,
                                          int argc,
                                          JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glDisableVertexAttribArray(static_cast<GLuint>(gi(ctx, argc, argv, 1)));
  return JS_UNDEFINED;
}

// vertexAttribPointer(index, size, type, normalized, stride, offset)
JSValue js_gl_vertex_attrib_pointer(JSContext* ctx,
                                    JSValueConst,
                                    int argc,
                                    JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glVertexAttribPointer(
        static_cast<GLuint>(gi(ctx, argc, argv, 1)), gi(ctx, argc, argv, 2),
        static_cast<GLenum>(gi(ctx, argc, argv, 3)),
        gi(ctx, argc, argv, 4) ? GL_TRUE : GL_FALSE, gi(ctx, argc, argv, 5),
        reinterpret_cast<const void*>(
            static_cast<uintptr_t>(gi(ctx, argc, argv, 6))));
  return JS_UNDEFINED;
}

// -- uniforms ----------------------------------------------------------------

JSValue js_gl_uniform1f(JSContext* ctx,
                        JSValueConst,
                        int argc,
                        JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glUniform1f(gi(ctx, argc, argv, 1),
                static_cast<GLfloat>(gd(ctx, argc, argv, 2)));
  return JS_UNDEFINED;
}
JSValue js_gl_uniform2f(JSContext* ctx,
                        JSValueConst,
                        int argc,
                        JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glUniform2f(gi(ctx, argc, argv, 1),
                static_cast<GLfloat>(gd(ctx, argc, argv, 2)),
                static_cast<GLfloat>(gd(ctx, argc, argv, 3)));
  return JS_UNDEFINED;
}
JSValue js_gl_uniform3f(JSContext* ctx,
                        JSValueConst,
                        int argc,
                        JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glUniform3f(gi(ctx, argc, argv, 1),
                static_cast<GLfloat>(gd(ctx, argc, argv, 2)),
                static_cast<GLfloat>(gd(ctx, argc, argv, 3)),
                static_cast<GLfloat>(gd(ctx, argc, argv, 4)));
  return JS_UNDEFINED;
}
JSValue js_gl_uniform4f(JSContext* ctx,
                        JSValueConst,
                        int argc,
                        JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glUniform4f(gi(ctx, argc, argv, 1),
                static_cast<GLfloat>(gd(ctx, argc, argv, 2)),
                static_cast<GLfloat>(gd(ctx, argc, argv, 3)),
                static_cast<GLfloat>(gd(ctx, argc, argv, 4)),
                static_cast<GLfloat>(gd(ctx, argc, argv, 5)));
  return JS_UNDEFINED;
}
JSValue js_gl_uniform1i(JSContext* ctx,
                        JSValueConst,
                        int argc,
                        JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glUniform1i(gi(ctx, argc, argv, 1), gi(ctx, argc, argv, 2));
  return JS_UNDEFINED;
}
JSValue js_gl_uniform2i(JSContext* ctx,
                        JSValueConst,
                        int argc,
                        JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glUniform2i(gi(ctx, argc, argv, 1), gi(ctx, argc, argv, 2),
                gi(ctx, argc, argv, 3));
  return JS_UNDEFINED;
}

// uniform{1,2,3,4}fv(location, array); count inferred from array length.
JSValue js_gl_uniform_fv(JSContext* ctx,
                         JSValueConst,
                         int argc,
                         JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_UNDEFINED;
  const int n = gi(ctx, argc, argv, 1);  // components per element (1..4)
  const GLint loc = gi(ctx, argc, argv, 2);
  std::vector<double> v;
  if (argc > 3)
    v = num_array(ctx, argv[3]);
  std::vector<GLfloat> f(v.begin(), v.end());
  const GLsizei count = n > 0 ? static_cast<GLsizei>(f.size() / n) : 0;
  if (count <= 0)
    return JS_UNDEFINED;
  if (n == 1)
    glUniform1fv(loc, count, f.data());
  else if (n == 2)
    glUniform2fv(loc, count, f.data());
  else if (n == 3)
    glUniform3fv(loc, count, f.data());
  else
    glUniform4fv(loc, count, f.data());
  return JS_UNDEFINED;
}

// uniform{1,2,3,4}iv(location, array); count inferred from array length.
JSValue js_gl_uniform_iv(JSContext* ctx,
                         JSValueConst,
                         int argc,
                         JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_UNDEFINED;
  const int n = gi(ctx, argc, argv, 1);
  const GLint loc = gi(ctx, argc, argv, 2);
  std::vector<double> v;
  if (argc > 3)
    v = num_array(ctx, argv[3]);
  std::vector<GLint> iv(v.begin(), v.end());
  const GLsizei count = n > 0 ? static_cast<GLsizei>(iv.size() / n) : 0;
  if (count <= 0)
    return JS_UNDEFINED;
  if (n == 1)
    glUniform1iv(loc, count, iv.data());
  else if (n == 2)
    glUniform2iv(loc, count, iv.data());
  else if (n == 3)
    glUniform3iv(loc, count, iv.data());
  else
    glUniform4iv(loc, count, iv.data());
  return JS_UNDEFINED;
}

// uniformMatrix{2,3,4}fv(dim, location, transpose, array)
JSValue js_gl_uniform_matrix(JSContext* ctx,
                             JSValueConst,
                             int argc,
                             JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_UNDEFINED;
  const int dim = gi(ctx, argc, argv, 1);  // 2, 3 or 4
  const GLint loc = gi(ctx, argc, argv, 2);
  const GLboolean transpose = gi(ctx, argc, argv, 3) ? GL_TRUE : GL_FALSE;
  std::vector<double> v;
  if (argc > 4)
    v = num_array(ctx, argv[4]);
  std::vector<GLfloat> f(v.begin(), v.end());
  const int per = dim * dim;
  const GLsizei count = per > 0 ? static_cast<GLsizei>(f.size() / per) : 0;
  if (count <= 0)
    return JS_UNDEFINED;
  if (dim == 2)
    glUniformMatrix2fv(loc, count, transpose, f.data());
  else if (dim == 3)
    glUniformMatrix3fv(loc, count, transpose, f.data());
  else
    glUniformMatrix4fv(loc, count, transpose, f.data());
  return JS_UNDEFINED;
}

// -- textures ----------------------------------------------------------------

// Premultiply RGBA8 pixel data's colour channels by their own alpha (a/255),
// matching what UNPACK_PREMULTIPLY_ALPHA_WEBGL does during a real browser's
// texture upload. GLES has no equivalent pixel-store flag (js_gl_pixel_storei
// above), so PIXI telling the (real) GL to premultiply on upload -- which it
// does for every ordinary texture, since BaseTexture's default alphaMode is
// UNPACK (= PREMULTIPLY_ON_UPLOAD) -- silently did nothing: textures uploaded
// with straight alpha, then blended by PIXI's NORMAL blend mode
// ([ONE, ONE_MINUS_SRC_ALPHA], which assumes premultiplied input) came out
// over-bright on every partially-transparent pixel -- window corners, any
// anti-aliased sprite edge. `src` is left untouched (it may be a canvas' own
// live pixel buffer, read again later by game code); the premultiplied copy
// goes into `out`.
void premultiply_rgba(const uint8_t* src,
                      size_t pixel_count,
                      std::vector<uint8_t>& out) {
  out.assign(src, src + pixel_count * 4);
  for (size_t i = 0; i < pixel_count; ++i) {
    uint8_t* p = &out[i * 4];
    const unsigned a = p[3];
    p[0] = static_cast<uint8_t>(p[0] * a / 255);
    p[1] = static_cast<uint8_t>(p[1] * a / 255);
    p[2] = static_cast<uint8_t>(p[2] * a / 255);
  }
}

// Whether context `handle` currently has UNPACK_PREMULTIPLY_ALPHA_WEBGL set.
bool premultiply_enabled(int handle) {
  return handle >= 1 && static_cast<size_t>(handle) <= g_premultiply.size() &&
         g_premultiply[static_cast<size_t>(handle) - 1];
}

// Reverse RGBA8 pixel data's row order top-to-bottom, matching what
// UNPACK_FLIP_Y_WEBGL does during a real browser's texture upload. GLES has
// no equivalent pixel-store flag (js_gl_pixel_storei above), so this is done
// on the CPU before the real upload call, the same story as premultiply_rgba
// just above (and, like it, applied to a `src` that is left untouched --
// it may be a canvas' own live pixel buffer, read again later by game code
// -- with the flipped copy going into `out`).
void flip_y_rgba(const uint8_t* src,
                 int width,
                 int height,
                 std::vector<uint8_t>& out) {
  const size_t row_bytes = static_cast<size_t>(width) * 4;
  out.resize(row_bytes * static_cast<size_t>(height));
  for (int y = 0; y < height; ++y) {
    std::memcpy(&out[static_cast<size_t>(y) * row_bytes],
                src + static_cast<size_t>(height - 1 - y) * row_bytes,
                row_bytes);
  }
}

// Whether context `handle` currently has UNPACK_FLIP_Y_WEBGL set.
bool flip_y_enabled(int handle) {
  return handle >= 1 && static_cast<size_t>(handle) <= g_flip_y.size() &&
         g_flip_y[static_cast<size_t>(handle) - 1];
}

JSValue js_gl_create_texture(JSContext* ctx,
                             JSValueConst,
                             int argc,
                             JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_NewInt32(ctx, 0);
  GLuint t = 0;
  glGenTextures(1, &t);
  return JS_NewInt32(ctx, static_cast<int32_t>(t));
}

JSValue js_gl_bind_texture(JSContext* ctx,
                           JSValueConst,
                           int argc,
                           JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glBindTexture(static_cast<GLenum>(gi(ctx, argc, argv, 1)),
                  static_cast<GLuint>(gi(ctx, argc, argv, 2)));
  return JS_UNDEFINED;
}

JSValue js_gl_tex_parameteri(JSContext* ctx,
                             JSValueConst,
                             int argc,
                             JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glTexParameteri(static_cast<GLenum>(gi(ctx, argc, argv, 1)),
                    static_cast<GLenum>(gi(ctx, argc, argv, 2)),
                    gi(ctx, argc, argv, 3));
  return JS_UNDEFINED;
}

// texImage2D(target, level, internalformat, w, h, border, format, type,
//            ArrayBufferView|null) — the sized/typed-array overload.
JSValue js_gl_tex_image_2d(JSContext* ctx,
                           JSValueConst,
                           int argc,
                           JSValueConst* argv) {
  const int handle = gi(ctx, argc, argv, 0);
  if (!bind(handle))
    return JS_UNDEFINED;
  const GLenum target = static_cast<GLenum>(gi(ctx, argc, argv, 1));
  const GLint level = gi(ctx, argc, argv, 2);
  const GLint internalformat = gi(ctx, argc, argv, 3);
  const GLsizei w = gi(ctx, argc, argv, 4);
  const GLsizei h = gi(ctx, argc, argv, 5);
  const GLint border = gi(ctx, argc, argv, 6);
  const GLenum format = static_cast<GLenum>(gi(ctx, argc, argv, 7));
  const GLenum type = static_cast<GLenum>(gi(ctx, argc, argv, 8));
  if (argc > 9 && !JS_IsNull(argv[9]) && !JS_IsUndefined(argv[9])) {
    JSValue hold;
    size_t len = 0;
    uint8_t* p = view_bytes(ctx, argv[9], &len, &hold);
    std::vector<uint8_t> flipped, premul;
    if (p && format == GL_RGBA && type == GL_UNSIGNED_BYTE) {
      if (flip_y_enabled(handle)) {
        flip_y_rgba(p, w, h, flipped);
        p = flipped.data();
      }
      if (premultiply_enabled(handle)) {
        premultiply_rgba(p, len / 4, premul);
        p = premul.data();
      }
    }
    glTexImage2D(target, level, internalformat, w, h, border, format, type, p);
    JS_FreeValue(ctx, hold);
  } else {
    glTexImage2D(target, level, internalformat, w, h, border, format, type,
                 nullptr);
  }
  return JS_UNDEFINED;
}

// texImage2D from a 2D canvas source: upload the canvas' RGBA buffer. The
// source overload PIXI uses to turn a rendered canvas into a texture. (See
// js_gl_pixel_storei's comment for UNPACK_FLIP_Y_WEBGL/
// UNPACK_PREMULTIPLY_ALPHA_WEBGL, both honoured below.)
JSValue js_gl_tex_image_2d_canvas(JSContext* ctx,
                                  JSValueConst,
                                  int argc,
                                  JSValueConst* argv) {
  const int handle = gi(ctx, argc, argv, 0);
  if (!bind(handle))
    return JS_UNDEFINED;
  int cw = 0, ch = 0;
  const uint8_t* px = mv_canvas_pixels(gi(ctx, argc, argv, 6), &cw, &ch);
  if (px) {
    std::vector<uint8_t> flipped, premul;
    if (flip_y_enabled(handle)) {
      flip_y_rgba(px, cw, ch, flipped);
      px = flipped.data();
    }
    if (premultiply_enabled(handle)) {
      premultiply_rgba(px, static_cast<size_t>(cw) * static_cast<size_t>(ch),
                       premul);
      px = premul.data();
    }
    glTexImage2D(static_cast<GLenum>(gi(ctx, argc, argv, 1)),
                 gi(ctx, argc, argv, 2), gi(ctx, argc, argv, 3), cw, ch, 0,
                 static_cast<GLenum>(gi(ctx, argc, argv, 4)),
                 static_cast<GLenum>(gi(ctx, argc, argv, 5)), px);
  }
  return JS_UNDEFINED;
}

// texSubImage2D(target, level, xoffset, yoffset, w, h, format, type,
//               ArrayBufferView|null) — the sized/typed-array overload, the
// counterpart of js_gl_tex_image_2d. A null view is a no-op rather than a GL
// call: unlike texImage2D (where null *allocates* storage) a null sub-upload
// has no meaning, and GLES2 would reject it.
JSValue js_gl_tex_sub_image_2d(JSContext* ctx,
                               JSValueConst,
                               int argc,
                               JSValueConst* argv) {
  const int handle = gi(ctx, argc, argv, 0);
  if (!bind(handle))
    return JS_UNDEFINED;
  if (argc <= 9 || JS_IsNull(argv[9]) || JS_IsUndefined(argv[9]))
    return JS_UNDEFINED;
  const GLsizei w = gi(ctx, argc, argv, 5);
  const GLsizei h = gi(ctx, argc, argv, 6);
  JSValue hold;
  size_t len = 0;
  uint8_t* p = view_bytes(ctx, argv[9], &len, &hold);
  if (p) {
    const GLenum format = static_cast<GLenum>(gi(ctx, argc, argv, 7));
    const GLenum type = static_cast<GLenum>(gi(ctx, argc, argv, 8));
    std::vector<uint8_t> flipped, premul;
    if (format == GL_RGBA && type == GL_UNSIGNED_BYTE) {
      if (flip_y_enabled(handle)) {
        flip_y_rgba(p, w, h, flipped);
        p = flipped.data();
      }
      if (premultiply_enabled(handle)) {
        premultiply_rgba(p, len / 4, premul);
        p = premul.data();
      }
    }
    glTexSubImage2D(static_cast<GLenum>(gi(ctx, argc, argv, 1)),
                    gi(ctx, argc, argv, 2), gi(ctx, argc, argv, 3),
                    gi(ctx, argc, argv, 4), w, h, format, type, p);
  }
  JS_FreeValue(ctx, hold);
  return JS_UNDEFINED;
}

// texSubImage2D from a 2D canvas/image source: write the source's RGBA buffer
// into an already-allocated texture at (xoffset, yoffset). This is the call
// that carries most of MZ's actual pixels: PIXI re-uploads a texture whose
// dimensions have not changed with texSubImage2D rather than texImage2D, so
// every bitmap redrawn after its first upload — window contents, rendered text,
// a Bitmap the game paints into — arrives here, and rmmz's Tilemap fills its
// 2048x2048 tile atlas by sub-uploading each tileset page into a quadrant of
// it.
JSValue js_gl_tex_sub_image_2d_canvas(JSContext* ctx,
                                      JSValueConst,
                                      int argc,
                                      JSValueConst* argv) {
  const int handle = gi(ctx, argc, argv, 0);
  if (!bind(handle))
    return JS_UNDEFINED;
  int cw = 0, ch = 0;
  const uint8_t* px = mv_canvas_pixels(gi(ctx, argc, argv, 7), &cw, &ch);
  if (px) {
    std::vector<uint8_t> flipped, premul;
    if (flip_y_enabled(handle)) {
      flip_y_rgba(px, cw, ch, flipped);
      px = flipped.data();
    }
    if (premultiply_enabled(handle)) {
      premultiply_rgba(px, static_cast<size_t>(cw) * static_cast<size_t>(ch),
                       premul);
      px = premul.data();
    }
    glTexSubImage2D(static_cast<GLenum>(gi(ctx, argc, argv, 1)),
                    gi(ctx, argc, argv, 2), gi(ctx, argc, argv, 3),
                    gi(ctx, argc, argv, 4), cw, ch,
                    static_cast<GLenum>(gi(ctx, argc, argv, 5)),
                    static_cast<GLenum>(gi(ctx, argc, argv, 6)), px);
  }
  return JS_UNDEFINED;
}

JSValue js_gl_generate_mipmap(JSContext* ctx,
                              JSValueConst,
                              int argc,
                              JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glGenerateMipmap(static_cast<GLenum>(gi(ctx, argc, argv, 1)));
  return JS_UNDEFINED;
}

JSValue js_gl_delete_texture(JSContext* ctx,
                             JSValueConst,
                             int argc,
                             JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0))) {
    GLuint t = static_cast<GLuint>(gi(ctx, argc, argv, 1));
    glDeleteTextures(1, &t);
  }
  return JS_UNDEFINED;
}

// -- framebuffers ------------------------------------------------------------

JSValue js_gl_create_framebuffer(JSContext* ctx,
                                 JSValueConst,
                                 int argc,
                                 JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_NewInt32(ctx, 0);
  GLuint f = 0;
  glGenFramebuffers(1, &f);
  return JS_NewInt32(ctx, static_cast<int32_t>(f));
}

// bindFramebuffer(target, fb). fb == 0 (WebGL's null default framebuffer) binds
// the context's own FBO, not GL framebuffer 0 (which does not exist for a
// surfaceless context).
JSValue js_gl_bind_framebuffer(JSContext* ctx,
                               JSValueConst,
                               int argc,
                               JSValueConst* argv) {
  mvgl::Context* c = bind(gi(ctx, argc, argv, 0));
  if (c) {
    GLuint fb = static_cast<GLuint>(gi(ctx, argc, argv, 2));
    if (fb == 0)
      fb = mvgl::default_framebuffer(c);
    glBindFramebuffer(static_cast<GLenum>(gi(ctx, argc, argv, 1)), fb);
  }
  return JS_UNDEFINED;
}

// framebufferTexture2D(target, attachment, textarget, texture, level)
JSValue js_gl_framebuffer_texture_2d(JSContext* ctx,
                                     JSValueConst,
                                     int argc,
                                     JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glFramebufferTexture2D(static_cast<GLenum>(gi(ctx, argc, argv, 1)),
                           static_cast<GLenum>(gi(ctx, argc, argv, 2)),
                           static_cast<GLenum>(gi(ctx, argc, argv, 3)),
                           static_cast<GLuint>(gi(ctx, argc, argv, 4)),
                           gi(ctx, argc, argv, 5));
  return JS_UNDEFINED;
}

// -- renderbuffers -----------------------------------------------------------
//
// These back the depth/stencil attachment PIXI adds to a *render texture*'s
// framebuffer. They used to be stubs (createRenderbuffer returned 0, the rest
// were no-ops) on the assumption that only the main FBO — which mvgl.cxx builds
// with its own packed DEPTH24_STENCIL8 buffer — ever needs one. That is not how
// MZ renders: `Scene_Base` puts a `ColorFilter` on every scene, so the scene is
// drawn into a filter render texture and only the filter's output quad touches
// the main FBO. rmmz's `WindowLayer.render` asks for a stencil there
// (`renderer.framebuffer.forceStencil()`) and then masks each window against
// the ones in front of it; with no attachment the stencil test always passes,
// so every window overpainted its neighbours.
//
// Two WebGL1 enums have no GLES2 equivalent and are translated here: the
// combined `DEPTH_STENCIL` internal format becomes `DEPTH24_STENCIL8`, and the
// combined `DEPTH_STENCIL_ATTACHMENT` point becomes an attach to both the depth
// and the stencil attachment (which is what the packed buffer feeds).

JSValue js_gl_create_renderbuffer(JSContext* ctx,
                                  JSValueConst,
                                  int argc,
                                  JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_NewInt32(ctx, 0);
  GLuint r = 0;
  glGenRenderbuffers(1, &r);
  return JS_NewInt32(ctx, static_cast<int32_t>(r));
}

JSValue js_gl_bind_renderbuffer(JSContext* ctx,
                                JSValueConst,
                                int argc,
                                JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glBindRenderbuffer(static_cast<GLenum>(gi(ctx, argc, argv, 1)),
                       static_cast<GLuint>(gi(ctx, argc, argv, 2)));
  return JS_UNDEFINED;
}

// renderbufferStorage(target, internalformat, width, height)
JSValue js_gl_renderbuffer_storage(JSContext* ctx,
                                   JSValueConst,
                                   int argc,
                                   JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_UNDEFINED;
  GLenum fmt = static_cast<GLenum>(gi(ctx, argc, argv, 2));
  if (fmt == GL_DEPTH_STENCIL)
    fmt = GL_DEPTH24_STENCIL8;
  glRenderbufferStorage(static_cast<GLenum>(gi(ctx, argc, argv, 1)), fmt,
                        gi(ctx, argc, argv, 3), gi(ctx, argc, argv, 4));
  return JS_UNDEFINED;
}

// framebufferRenderbuffer(target, attachment, renderbuffertarget, renderbuffer)
JSValue js_gl_framebuffer_renderbuffer(JSContext* ctx,
                                       JSValueConst,
                                       int argc,
                                       JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_UNDEFINED;
  const GLenum target = static_cast<GLenum>(gi(ctx, argc, argv, 1));
  const GLenum attach = static_cast<GLenum>(gi(ctx, argc, argv, 2));
  const GLenum rbtarget = static_cast<GLenum>(gi(ctx, argc, argv, 3));
  const GLuint rb = static_cast<GLuint>(gi(ctx, argc, argv, 4));
  if (attach == GL_DEPTH_STENCIL_ATTACHMENT) {
    glFramebufferRenderbuffer(target, GL_DEPTH_ATTACHMENT, rbtarget, rb);
    glFramebufferRenderbuffer(target, GL_STENCIL_ATTACHMENT, rbtarget, rb);
  } else {
    glFramebufferRenderbuffer(target, attach, rbtarget, rb);
  }
  return JS_UNDEFINED;
}

JSValue js_gl_delete_renderbuffer(JSContext* ctx,
                                  JSValueConst,
                                  int argc,
                                  JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0))) {
    GLuint r = static_cast<GLuint>(gi(ctx, argc, argv, 1));
    glDeleteRenderbuffers(1, &r);
  }
  return JS_UNDEFINED;
}

JSValue js_gl_check_framebuffer_status(JSContext* ctx,
                                       JSValueConst,
                                       int argc,
                                       JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_NewInt32(ctx, 0);
  return JS_NewInt32(ctx, static_cast<int32_t>(glCheckFramebufferStatus(
                              static_cast<GLenum>(gi(ctx, argc, argv, 1)))));
}

JSValue js_gl_delete_framebuffer(JSContext* ctx,
                                 JSValueConst,
                                 int argc,
                                 JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0))) {
    GLuint f = static_cast<GLuint>(gi(ctx, argc, argv, 1));
    glDeleteFramebuffers(1, &f);
  }
  return JS_UNDEFINED;
}

// -- draw & read -------------------------------------------------------------

JSValue js_gl_draw_arrays(JSContext* ctx,
                          JSValueConst,
                          int argc,
                          JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glDrawArrays(static_cast<GLenum>(gi(ctx, argc, argv, 1)),
                 gi(ctx, argc, argv, 2), gi(ctx, argc, argv, 3));
  return JS_UNDEFINED;
}

// drawElements(mode, count, type, offset)
JSValue js_gl_draw_elements(JSContext* ctx,
                            JSValueConst,
                            int argc,
                            JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glDrawElements(static_cast<GLenum>(gi(ctx, argc, argv, 1)),
                   gi(ctx, argc, argv, 2),
                   static_cast<GLenum>(gi(ctx, argc, argv, 3)),
                   reinterpret_cast<const void*>(
                       static_cast<uintptr_t>(gi(ctx, argc, argv, 4))));
  return JS_UNDEFINED;
}

// readPixels(x, y, w, h, format, type, ArrayBufferView) — fills the view.
JSValue js_gl_read_pixels(JSContext* ctx,
                          JSValueConst,
                          int argc,
                          JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_UNDEFINED;
  if (argc > 7) {
    JSValue hold;
    size_t len = 0;
    uint8_t* p = view_bytes(ctx, argv[7], &len, &hold);
    if (p)
      glReadPixels(gi(ctx, argc, argv, 1), gi(ctx, argc, argv, 2),
                   gi(ctx, argc, argv, 3), gi(ctx, argc, argv, 4),
                   static_cast<GLenum>(gi(ctx, argc, argv, 5)),
                   static_cast<GLenum>(gi(ctx, argc, argv, 6)), p);
    JS_FreeValue(ctx, hold);
  }
  return JS_UNDEFINED;
}

// -- queries -----------------------------------------------------------------

// getParameter for the integer pnames (glGetIntegerv, first component).
JSValue js_gl_get_int_param(JSContext* ctx,
                            JSValueConst,
                            int argc,
                            JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_NewInt32(ctx, 0);
  GLint v = 0;
  glGetIntegerv(static_cast<GLenum>(gi(ctx, argc, argv, 1)), &v);
  return JS_NewInt32(ctx, v);
}

// getParameter for the string pnames (VERSION/VENDOR/RENDERER/SL_VERSION).
JSValue js_gl_get_string(JSContext* ctx,
                         JSValueConst,
                         int argc,
                         JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_NewString(ctx, "");
  const GLubyte* s = glGetString(static_cast<GLenum>(gi(ctx, argc, argv, 1)));
  return JS_NewString(ctx, s ? reinterpret_cast<const char*>(s) : "");
}

JSValue js_gl_get_error(JSContext* ctx,
                        JSValueConst,
                        int argc,
                        JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_NewInt32(ctx, 0);
  return JS_NewInt32(ctx, static_cast<int32_t>(glGetError()));
}

JSValue js_gl_finish(JSContext* ctx,
                     JSValueConst,
                     int argc,
                     JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glFinish();
  return JS_UNDEFINED;
}

JSValue js_gl_flush(JSContext* ctx,
                    JSValueConst,
                    int argc,
                    JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)))
    glFlush();
  return JS_UNDEFINED;
}

// -- extensions: OES_vertex_array_object, ANGLE_instanced_arrays -------------
//
// PIXI's GeometrySystem.contextChange (see libs/pixi.js in a fetched MZ
// corescript) checks `gl.createVertexArray`/`gl.vertexAttribDivisor` first
// (the WebGL2 names) and, missing those, falls back to
// `gl.getExtension('OES_vertex_array_object')` /
// `gl.getExtension('ANGLE_instanced_arrays')` and calls the *ANGLE/OES-suffixed
// methods on the returned object. Both extensions were previously unavailable
// (getExtension always returned null, see its comment below), so every draw
// went through PIXI's own no-VAO fallback path (`gl.createVertexArray` a
// no-op, `hasVao`/`hasInstance` false) -- functionally correct but slower.
//
// The functions the two extensions need (glGenVertexArrays,
// glVertexAttribDivisor, ...) are GLES 3.0 core, absent from the GLES2 header
// this file compiles against, so they are loaded dynamically via
// eglGetProcAddress -- the same idiom mvgl.cxx uses for its own EGL
// extensions. mvgl.cxx's context is created ES3-first (falling back to ES2
// only where ES3 is unavailable, see bind_context), so the bare core name is
// tried first here too: on the apt/nix llvmpipe driver this is confirmed
// genuinely functional, while eglGetProcAddress happily hands back a non-null
// pointer for the legacy ANGLE-suffixed names too (per spec, an
// implementation may resolve any name) that silently drew nothing when tried
// first -- ANGLE_instanced_arrays is not a driver extension llvmpipe actually
// implements, unlike OES_vertex_array_object, whose OES-suffixed entry points
// did work; non-null is not sufficient evidence of "real", so core-first is
// the safe default and the suffixed name is only the fallback for a genuine
// GLES2-only driver with no core entry points at all. A null pointer after
// both lookups means the driver has neither, and the extension is then not
// advertised -- PIXI's existing fallback runs exactly as before M6.3c.
typedef void(GL_APIENTRYP PFNMVGENVERTEXARRAYSPROC)(GLsizei, GLuint*);
typedef void(GL_APIENTRYP PFNMVBINDVERTEXARRAYPROC)(GLuint);
typedef void(GL_APIENTRYP PFNMVDELETEVERTEXARRAYSPROC)(GLsizei, const GLuint*);
typedef GLboolean(GL_APIENTRYP PFNMVISVERTEXARRAYPROC)(GLuint);
typedef void(GL_APIENTRYP PFNMVVERTEXATTRIBDIVISORPROC)(GLuint, GLuint);
typedef void(GL_APIENTRYP PFNMVDRAWARRAYSINSTANCEDPROC)(GLenum,
                                                        GLint,
                                                        GLsizei,
                                                        GLsizei);
typedef void(GL_APIENTRYP PFNMVDRAWELEMENTSINSTANCEDPROC)(GLenum,
                                                          GLsizei,
                                                          GLenum,
                                                          const void*,
                                                          GLsizei);

// eglGetProcAddress under `core`, falling back to `suffixed` (see the section
// comment above); nullptr if neither resolves.
void* load_ext_proc(const char* core, const char* suffixed) {
  void* p = reinterpret_cast<void*>(eglGetProcAddress(core));
  return p ? p : reinterpret_cast<void*>(eglGetProcAddress(suffixed));
}

struct VaoExt {
  bool tried = false;
  PFNMVGENVERTEXARRAYSPROC gen = nullptr;
  PFNMVBINDVERTEXARRAYPROC bind_vao = nullptr;
  PFNMVDELETEVERTEXARRAYSPROC del = nullptr;
  PFNMVISVERTEXARRAYPROC is_vao = nullptr;
  bool ok() const { return gen && bind_vao && del && is_vao; }
};
VaoExt& vao_ext() {
  static VaoExt v;
  if (v.tried)
    return v;
  v.tried = true;
  v.gen = reinterpret_cast<PFNMVGENVERTEXARRAYSPROC>(
      load_ext_proc("glGenVertexArrays", "glGenVertexArraysOES"));
  v.bind_vao = reinterpret_cast<PFNMVBINDVERTEXARRAYPROC>(
      load_ext_proc("glBindVertexArray", "glBindVertexArrayOES"));
  v.del = reinterpret_cast<PFNMVDELETEVERTEXARRAYSPROC>(
      load_ext_proc("glDeleteVertexArrays", "glDeleteVertexArraysOES"));
  v.is_vao = reinterpret_cast<PFNMVISVERTEXARRAYPROC>(
      load_ext_proc("glIsVertexArray", "glIsVertexArrayOES"));
  return v;
}

struct InstancedExt {
  bool tried = false;
  PFNMVVERTEXATTRIBDIVISORPROC divisor = nullptr;
  PFNMVDRAWARRAYSINSTANCEDPROC draw_arrays = nullptr;
  PFNMVDRAWELEMENTSINSTANCEDPROC draw_elements = nullptr;
  bool ok() const { return divisor && draw_arrays && draw_elements; }
};
InstancedExt& instanced_ext() {
  static InstancedExt v;
  if (v.tried)
    return v;
  v.tried = true;
  v.divisor = reinterpret_cast<PFNMVVERTEXATTRIBDIVISORPROC>(
      load_ext_proc("glVertexAttribDivisor", "glVertexAttribDivisorANGLE"));
  v.draw_arrays = reinterpret_cast<PFNMVDRAWARRAYSINSTANCEDPROC>(
      load_ext_proc("glDrawArraysInstanced", "glDrawArraysInstancedANGLE"));
  v.draw_elements = reinterpret_cast<PFNMVDRAWELEMENTSINSTANCEDPROC>(
      load_ext_proc("glDrawElementsInstanced", "glDrawElementsInstancedANGLE"));
  return v;
}

JSValue js_gl_ext_vao_available(JSContext* ctx,
                                JSValueConst,
                                int argc,
                                JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_NewBool(ctx, 0);
  return JS_NewBool(ctx, vao_ext().ok());
}

JSValue js_gl_ext_create_vertex_array(JSContext* ctx,
                                      JSValueConst,
                                      int argc,
                                      JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)) || !vao_ext().ok())
    return JS_NewInt32(ctx, 0);
  GLuint v = 0;
  vao_ext().gen(1, &v);
  return JS_NewInt32(ctx, static_cast<int32_t>(v));
}

JSValue js_gl_ext_bind_vertex_array(JSContext* ctx,
                                    JSValueConst,
                                    int argc,
                                    JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)) && vao_ext().ok())
    vao_ext().bind_vao(static_cast<GLuint>(gi(ctx, argc, argv, 1)));
  return JS_UNDEFINED;
}

JSValue js_gl_ext_delete_vertex_array(JSContext* ctx,
                                      JSValueConst,
                                      int argc,
                                      JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)) && vao_ext().ok()) {
    GLuint v = static_cast<GLuint>(gi(ctx, argc, argv, 1));
    vao_ext().del(1, &v);
  }
  return JS_UNDEFINED;
}

JSValue js_gl_ext_is_vertex_array(JSContext* ctx,
                                  JSValueConst,
                                  int argc,
                                  JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)) || !vao_ext().ok())
    return JS_NewBool(ctx, 0);
  return JS_NewBool(
      ctx, vao_ext().is_vao(static_cast<GLuint>(gi(ctx, argc, argv, 1))));
}

JSValue js_gl_ext_instanced_available(JSContext* ctx,
                                      JSValueConst,
                                      int argc,
                                      JSValueConst* argv) {
  if (!bind(gi(ctx, argc, argv, 0)))
    return JS_NewBool(ctx, 0);
  return JS_NewBool(ctx, instanced_ext().ok());
}

// vertexAttribDivisorANGLE(index, divisor)
JSValue js_gl_ext_vertex_attrib_divisor(JSContext* ctx,
                                        JSValueConst,
                                        int argc,
                                        JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)) && instanced_ext().ok())
    instanced_ext().divisor(static_cast<GLuint>(gi(ctx, argc, argv, 1)),
                            static_cast<GLuint>(gi(ctx, argc, argv, 2)));
  return JS_UNDEFINED;
}

// drawArraysInstancedANGLE(mode, first, count, primcount)
JSValue js_gl_ext_draw_arrays_instanced(JSContext* ctx,
                                        JSValueConst,
                                        int argc,
                                        JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)) && instanced_ext().ok())
    instanced_ext().draw_arrays(static_cast<GLenum>(gi(ctx, argc, argv, 1)),
                                gi(ctx, argc, argv, 2), gi(ctx, argc, argv, 3),
                                gi(ctx, argc, argv, 4));
  return JS_UNDEFINED;
}

// drawElementsInstancedANGLE(mode, count, type, offset, primcount)
JSValue js_gl_ext_draw_elements_instanced(JSContext* ctx,
                                          JSValueConst,
                                          int argc,
                                          JSValueConst* argv) {
  if (bind(gi(ctx, argc, argv, 0)) && instanced_ext().ok())
    instanced_ext().draw_elements(
        static_cast<GLenum>(gi(ctx, argc, argv, 1)), gi(ctx, argc, argv, 2),
        static_cast<GLenum>(gi(ctx, argc, argv, 3)),
        reinterpret_cast<const void*>(
            static_cast<uintptr_t>(gi(ctx, argc, argv, 4))),
        gi(ctx, argc, argv, 5));
  return JS_UNDEFINED;
}

void reg(JSContext* ctx,
         JSValue g,
         const char* name,
         JSCFunction* fn,
         int argc) {
  JS_SetPropertyStr(ctx, g, name, JS_NewCFunction(ctx, fn, name, argc));
}

// The JS half: the WebGLRenderingContext prototype (constants + methods
// delegating to the __mv_gl* natives). Evaluated after the natives register.
// getContext("webgl") in the canvas shim (mvcanvas.cxx) constructs this.
const char* kWebGLPreamble = R"MVJS(
(function (g) {
  'use strict';
  // Standard WebGL1 enum values (identical to the GLES2 tokens). Literal so the
  // table is self-contained and independent of which GL headers are present.
  var K = {
    DEPTH_BUFFER_BIT: 0x0100, STENCIL_BUFFER_BIT: 0x0400, COLOR_BUFFER_BIT: 0x4000,
    POINTS: 0, LINES: 1, LINE_LOOP: 2, LINE_STRIP: 3,
    TRIANGLES: 4, TRIANGLE_STRIP: 5, TRIANGLE_FAN: 6,
    ZERO: 0, ONE: 1, SRC_COLOR: 0x0300, ONE_MINUS_SRC_COLOR: 0x0301,
    SRC_ALPHA: 0x0302, ONE_MINUS_SRC_ALPHA: 0x0303, DST_ALPHA: 0x0304,
    ONE_MINUS_DST_ALPHA: 0x0305, DST_COLOR: 0x0306, ONE_MINUS_DST_COLOR: 0x0307,
    SRC_ALPHA_SATURATE: 0x0308, CONSTANT_COLOR: 0x8001,
    ONE_MINUS_CONSTANT_COLOR: 0x8002, CONSTANT_ALPHA: 0x8003,
    ONE_MINUS_CONSTANT_ALPHA: 0x8004, BLEND_COLOR: 0x8005,
    FUNC_ADD: 0x8006, FUNC_SUBTRACT: 0x800A, FUNC_REVERSE_SUBTRACT: 0x800B,
    BLEND_EQUATION: 0x8009, BLEND_EQUATION_RGB: 0x8009, BLEND_EQUATION_ALPHA: 0x883D,
    BLEND_DST_RGB: 0x80C8, BLEND_SRC_RGB: 0x80C9, BLEND_DST_ALPHA: 0x80CA,
    BLEND_SRC_ALPHA: 0x80CB, BLEND: 0x0BE2,
    ARRAY_BUFFER: 0x8892, ELEMENT_ARRAY_BUFFER: 0x8893,
    ARRAY_BUFFER_BINDING: 0x8894, ELEMENT_ARRAY_BUFFER_BINDING: 0x8895,
    STREAM_DRAW: 0x88E0, STATIC_DRAW: 0x88E4, DYNAMIC_DRAW: 0x88E8,
    BUFFER_SIZE: 0x8764, BUFFER_USAGE: 0x8765,
    FRONT: 0x0404, BACK: 0x0405, FRONT_AND_BACK: 0x0408,
    CULL_FACE: 0x0B44, DEPTH_TEST: 0x0B71, STENCIL_TEST: 0x0B90,
    DITHER: 0x0BD0, SCISSOR_TEST: 0x0C11,
    POLYGON_OFFSET_FILL: 0x8037, SAMPLE_ALPHA_TO_COVERAGE: 0x809E,
    SAMPLE_COVERAGE: 0x80A0,
    NO_ERROR: 0, INVALID_ENUM: 0x0500, INVALID_VALUE: 0x0501,
    INVALID_OPERATION: 0x0502, OUT_OF_MEMORY: 0x0505,
    INVALID_FRAMEBUFFER_OPERATION: 0x0506, CONTEXT_LOST_WEBGL: 0x9242,
    CW: 0x0900, CCW: 0x0901,
    NEVER: 0x0200, LESS: 0x0201, EQUAL: 0x0202, LEQUAL: 0x0203,
    GREATER: 0x0204, NOTEQUAL: 0x0205, GEQUAL: 0x0206, ALWAYS: 0x0207,
    KEEP: 0x1E00, REPLACE: 0x1E01, INCR: 0x1E02, DECR: 0x1E03,
    INVERT: 0x150A, INCR_WRAP: 0x8507, DECR_WRAP: 0x8508,
    BYTE: 0x1400, UNSIGNED_BYTE: 0x1401, SHORT: 0x1402, UNSIGNED_SHORT: 0x1403,
    INT: 0x1404, UNSIGNED_INT: 0x1405, FLOAT: 0x1406,
    DEPTH_COMPONENT: 0x1902, ALPHA: 0x1906, RGB: 0x1907, RGBA: 0x1908,
    LUMINANCE: 0x1909, LUMINANCE_ALPHA: 0x190A,
    UNSIGNED_SHORT_4_4_4_4: 0x8033, UNSIGNED_SHORT_5_5_5_1: 0x8034,
    UNSIGNED_SHORT_5_6_5: 0x8363,
    FRAGMENT_SHADER: 0x8B30, VERTEX_SHADER: 0x8B31,
    COMPILE_STATUS: 0x8B81, DELETE_STATUS: 0x8B80, LINK_STATUS: 0x8B82,
    VALIDATE_STATUS: 0x8B83, ATTACHED_SHADERS: 0x8B85,
    ACTIVE_UNIFORMS: 0x8B86, ACTIVE_ATTRIBUTES: 0x8B89,
    SHADING_LANGUAGE_VERSION: 0x8B8C, CURRENT_PROGRAM: 0x8B8D,
    SHADER_TYPE: 0x8B4F,
    MAX_VERTEX_ATTRIBS: 0x8869, MAX_VERTEX_UNIFORM_VECTORS: 0x8DFB,
    MAX_VARYING_VECTORS: 0x8DFC, MAX_COMBINED_TEXTURE_IMAGE_UNITS: 0x8B4D,
    MAX_VERTEX_TEXTURE_IMAGE_UNITS: 0x8B4C, MAX_TEXTURE_IMAGE_UNITS: 0x8872,
    MAX_FRAGMENT_UNIFORM_VECTORS: 0x8DFD, MAX_TEXTURE_SIZE: 0x0D33,
    MAX_CUBE_MAP_TEXTURE_SIZE: 0x851C, MAX_RENDERBUFFER_SIZE: 0x84E8,
    MAX_VIEWPORT_DIMS: 0x0D3A, SUBPIXEL_BITS: 0x0D50,
    ALIASED_POINT_SIZE_RANGE: 0x846D, ALIASED_LINE_WIDTH_RANGE: 0x846E,
    RED_BITS: 0x0D52, GREEN_BITS: 0x0D53, BLUE_BITS: 0x0D54,
    ALPHA_BITS: 0x0D55, DEPTH_BITS: 0x0D56, STENCIL_BITS: 0x0D57,
    VIEWPORT: 0x0BA2, SCISSOR_BOX: 0x0C10, VERSION: 0x1F02,
    VENDOR: 0x1F00, RENDERER: 0x1F01, EXTENSIONS: 0x1F03,
    NEAREST: 0x2600, LINEAR: 0x2601,
    NEAREST_MIPMAP_NEAREST: 0x2700, LINEAR_MIPMAP_NEAREST: 0x2701,
    NEAREST_MIPMAP_LINEAR: 0x2702, LINEAR_MIPMAP_LINEAR: 0x2703,
    TEXTURE_MAG_FILTER: 0x2800, TEXTURE_MIN_FILTER: 0x2801,
    TEXTURE_WRAP_S: 0x2802, TEXTURE_WRAP_T: 0x2803,
    TEXTURE_2D: 0x0DE1, TEXTURE: 0x1702, TEXTURE_CUBE_MAP: 0x8513,
    TEXTURE_BINDING_2D: 0x8069, TEXTURE_BINDING_CUBE_MAP: 0x8514,
    TEXTURE_CUBE_MAP_POSITIVE_X: 0x8515, TEXTURE_CUBE_MAP_NEGATIVE_X: 0x8516,
    TEXTURE_CUBE_MAP_POSITIVE_Y: 0x8517, TEXTURE_CUBE_MAP_NEGATIVE_Y: 0x8518,
    TEXTURE_CUBE_MAP_POSITIVE_Z: 0x8519, TEXTURE_CUBE_MAP_NEGATIVE_Z: 0x851A,
    TEXTURE0: 0x84C0, ACTIVE_TEXTURE: 0x84E0,
    REPEAT: 0x2901, CLAMP_TO_EDGE: 0x812F, MIRRORED_REPEAT: 0x8370,
    FLOAT_VEC2: 0x8B50, FLOAT_VEC3: 0x8B51, FLOAT_VEC4: 0x8B52,
    INT_VEC2: 0x8B53, INT_VEC3: 0x8B54, INT_VEC4: 0x8B55, BOOL: 0x8B56,
    BOOL_VEC2: 0x8B57, BOOL_VEC3: 0x8B58, BOOL_VEC4: 0x8B59,
    FLOAT_MAT2: 0x8B5A, FLOAT_MAT3: 0x8B5B, FLOAT_MAT4: 0x8B5C,
    SAMPLER_2D: 0x8B5E, SAMPLER_CUBE: 0x8B60,
    LOW_FLOAT: 0x8DF0, MEDIUM_FLOAT: 0x8DF1, HIGH_FLOAT: 0x8DF2,
    LOW_INT: 0x8DF3, MEDIUM_INT: 0x8DF4, HIGH_INT: 0x8DF5,
    FRAMEBUFFER: 0x8D40, RENDERBUFFER: 0x8D41,
    RGBA4: 0x8056, RGB5_A1: 0x8057, RGB565: 0x8D62,
    DEPTH_COMPONENT16: 0x81A5, STENCIL_INDEX8: 0x8D48, DEPTH_STENCIL: 0x84F9,
    COLOR_ATTACHMENT0: 0x8CE0, DEPTH_ATTACHMENT: 0x8D00,
    STENCIL_ATTACHMENT: 0x8D20, DEPTH_STENCIL_ATTACHMENT: 0x821A, NONE: 0,
    FRAMEBUFFER_COMPLETE: 0x8CD5, FRAMEBUFFER_INCOMPLETE_ATTACHMENT: 0x8CD6,
    FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT: 0x8CD7,
    FRAMEBUFFER_INCOMPLETE_DIMENSIONS: 0x8CD9, FRAMEBUFFER_UNSUPPORTED: 0x8CDD,
    FRAMEBUFFER_BINDING: 0x8CA6, RENDERBUFFER_BINDING: 0x8CA7,
    GENERATE_MIPMAP_HINT: 0x8192, DONT_CARE: 0x1100, FASTEST: 0x1101,
    NICEST: 0x1102, UNPACK_ALIGNMENT: 0x0CF5, PACK_ALIGNMENT: 0x0D05,
    UNPACK_FLIP_Y_WEBGL: 0x9240, UNPACK_PREMULTIPLY_ALPHA_WEBGL: 0x9241,
    UNPACK_COLORSPACE_CONVERSION_WEBGL: 0x9243, BROWSER_DEFAULT_WEBGL: 0x9244,
  };

  function WebGLRenderingContext(canvas) {
    this.canvas = canvas;
    // A default (0x0) canvas must still yield a context — browsers do, and
    // Utils.canUseWebGL() probes exactly that — while the native backend needs
    // a >= 1x1 render target. Clamp here; PIXI sizes the canvas before it
    // renders (resizing the GL FBO to match is M6.3c).
    var w = canvas._w > 0 ? canvas._w : 1;
    var h = canvas._h > 0 ? canvas._h : 1;
    this.drawingBufferWidth = w;
    this.drawingBufferHeight = h;
    this.__gl = g.__mv_glCreate(w, h);
    this._ext = {};
  }
  // Follow the canvas' size. The canvas' width/height setters call this (see
  // mvcanvas.cxx) so the native render target tracks the game's screen
  // resolution instead of staying at the 1x1 it was created with.
  WebGLRenderingContext.prototype.__mv_resize = function (w, h) {
    w = w | 0; h = h | 0;
    if (w <= 0 || h <= 0 || !this.__gl) return;
    if (w === this.drawingBufferWidth && h === this.drawingBufferHeight) return;
    if (g.__mv_glResize(this.__gl, w, h)) {
      this.drawingBufferWidth = w;
      this.drawingBufferHeight = h;
    }
  };
  var P = WebGLRenderingContext.prototype;
  // The GL enums live both on the prototype (read as `gl.RGBA`) and as static
  // properties on the constructor (`WebGLRenderingContext.RGBA`). PIXI v5's
  // ScissorSystem/StencilSystem read the enum off the *constructor* at
  // renderer-construction time (e.g. `WebGLRenderingContext.SCISSOR_TEST`), so
  // without the statics `new PIXI.Renderer` throws a ReferenceError before it
  // can create a context. Mirror the browser, which exposes both.
  for (var k in K) {
    P[k] = K[k];
    WebGLRenderingContext[k] = K[k];
  }

  // Whole-context state.
  P.viewport = function (x, y, w, h) { g.__mv_glViewport(this.__gl, x, y, w, h); };
  P.scissor = function (x, y, w, h) { g.__mv_glScissor(this.__gl, x, y, w, h); };
  P.clearColor = function (r, gg, b, a) { g.__mv_glClearColor(this.__gl, r, gg, b, a); };
  P.clear = function (m) { g.__mv_glClear(this.__gl, m); };
  P.enable = function (c) { g.__mv_glEnable(this.__gl, c); };
  P.disable = function (c) { g.__mv_glDisable(this.__gl, c); };
  P.blendFunc = function (s, d) { g.__mv_glBlendFunc(this.__gl, s, d); };
  P.blendFuncSeparate = function (a, b, c, d) { g.__mv_glBlendFuncSeparate(this.__gl, a, b, c, d); };
  P.blendEquation = function (m) { g.__mv_glBlendEquation(this.__gl, m); };
  P.blendEquationSeparate = function (a, b) { g.__mv_glBlendEquationSeparate(this.__gl, a, b); };
  P.depthFunc = function (f) { g.__mv_glDepthFunc(this.__gl, f); };
  P.depthMask = function (f) { g.__mv_glDepthMask(this.__gl, f ? 1 : 0); };
  P.colorMask = function (r, gg, b, a) { g.__mv_glColorMask(this.__gl, r ? 1 : 0, gg ? 1 : 0, b ? 1 : 0, a ? 1 : 0); };
  P.cullFace = function (m) { g.__mv_glCullFace(this.__gl, m); };
  P.frontFace = function (m) { g.__mv_glFrontFace(this.__gl, m); };
  P.pixelStorei = function (p, v) { g.__mv_glPixelStorei(this.__gl, p, (v === true ? 1 : v === false ? 0 : v)); };
  P.activeTexture = function (t) { g.__mv_glActiveTexture(this.__gl, t); };
  P.hint = function () {};
  P.lineWidth = function () {};
  P.depthRange = function () {};
  // Stencil state, mapped onto GL. The off-screen FBO carries a packed
  // DEPTH24_STENCIL8 renderbuffer (mvgl::create/resize), so the buffer was
  // always there — these four were the stubs keeping it unprogrammed. MZ's
  // `WindowLayer.render` masks with it: each window is drawn with the test set
  // to "pass where the buffer is 0", then its shape is stamped with REPLACE, so
  // a window behind cannot paint over the one in front. With the stubs, every
  // window overpainted its neighbours.
  //
  // `clearStencil` also has to *exist* whatever it does: `WindowLayer.render`
  // calls it on every frame that draws a window, and a missing method throws a
  // TypeError inside PIXI's ticker, which is fatal rather than transient — PIXI
  // v5 re-arms its requestAnimationFrame only after `update()` returns, so one
  // throw stops the game loop for good.
  P.stencilFunc = function (f, ref, mask) { g.__mv_glStencilFunc(this.__gl, f, ref, mask); };
  P.stencilOp = function (sf, zf, zp) { g.__mv_glStencilOp(this.__gl, sf, zf, zp); };
  P.stencilMask = function (m) { g.__mv_glStencilMask(this.__gl, m); };
  P.clearStencil = function (s) { g.__mv_glClearStencil(this.__gl, s | 0); };
  // Depth-offset state PIXI's State manager applies; no effect on a 2D scene
  // drawn without a depth buffer.
  P.polygonOffset = function () {};

  // Shaders & programs.
  P.createShader = function (t) { return g.__mv_glCreateShader(this.__gl, t); };
  P.shaderSource = function (s, src) { g.__mv_glShaderSource(this.__gl, s, src); };
  P.compileShader = function (s) { g.__mv_glCompileShader(this.__gl, s); };
  P.getShaderParameter = function (s, p) { return g.__mv_glGetShaderParameter(this.__gl, s, p) ? true : false; };
  P.getShaderInfoLog = function (s) { return g.__mv_glGetShaderInfoLog(this.__gl, s); };
  P.deleteShader = function (s) { g.__mv_glDeleteShader(this.__gl, s); };
  P.getShaderPrecisionFormat = function () { return { rangeMin: 127, rangeMax: 127, precision: 23 }; };
  P.createProgram = function () { return g.__mv_glCreateProgram(this.__gl); };
  P.attachShader = function (p, s) { g.__mv_glAttachShader(this.__gl, p, s); };
  P.detachShader = function () {};
  P.bindAttribLocation = function (p, i, n) { g.__mv_glBindAttribLocation(this.__gl, p, i, n); };
  P.linkProgram = function (p) { g.__mv_glLinkProgram(this.__gl, p); };
  P.validateProgram = function () {};
  P.getProgramParameter = function (p, n) {
    var v = g.__mv_glGetProgramParameter(this.__gl, p, n);
    return (n === K.LINK_STATUS || n === K.VALIDATE_STATUS || n === K.DELETE_STATUS) ? !!v : v;
  };
  P.getProgramInfoLog = function (p) { return g.__mv_glGetProgramInfoLog(this.__gl, p); };
  P.useProgram = function (p) { g.__mv_glUseProgram(this.__gl, p); };
  P.deleteProgram = function (p) { g.__mv_glDeleteProgram(this.__gl, p); };
  P.getAttribLocation = function (p, n) { return g.__mv_glGetAttribLocation(this.__gl, p, n); };
  P.getUniformLocation = function (p, n) {
    var l = g.__mv_glGetUniformLocation(this.__gl, p, n);
    return l < 0 ? null : l;
  };
  P.getActiveUniform = function (p, i) { return g.__mv_glGetActiveUniform(this.__gl, p, i); };
  P.getActiveAttrib = function (p, i) { return g.__mv_glGetActiveAttrib(this.__gl, p, i); };

  // Buffers & vertex attributes.
  P.createBuffer = function () { return g.__mv_glCreateBuffer(this.__gl); };
  P.bindBuffer = function (t, b) { g.__mv_glBindBuffer(this.__gl, t, b || 0); };
  P.bufferData = function (t, d, u) { g.__mv_glBufferData(this.__gl, t, d, u); };
  P.bufferSubData = function (t, o, d) { g.__mv_glBufferSubData(this.__gl, t, o, d); };
  P.deleteBuffer = function (b) { g.__mv_glDeleteBuffer(this.__gl, b); };
  P.enableVertexAttribArray = function (i) { g.__mv_glEnableVertexAttribArray(this.__gl, i); };
  P.disableVertexAttribArray = function (i) { g.__mv_glDisableVertexAttribArray(this.__gl, i); };
  P.vertexAttribPointer = function (i, s, t, n, st, o) { g.__mv_glVertexAttribPointer(this.__gl, i, s, t, n ? 1 : 0, st, o); };

  // Uniforms.
  P.uniform1f = function (l, x) { if (l !== null) g.__mv_glUniform1f(this.__gl, l, x); };
  P.uniform2f = function (l, x, y) { if (l !== null) g.__mv_glUniform2f(this.__gl, l, x, y); };
  P.uniform3f = function (l, x, y, z) { if (l !== null) g.__mv_glUniform3f(this.__gl, l, x, y, z); };
  P.uniform4f = function (l, x, y, z, w) { if (l !== null) g.__mv_glUniform4f(this.__gl, l, x, y, z, w); };
  P.uniform1i = function (l, x) { if (l !== null) g.__mv_glUniform1i(this.__gl, l, x); };
  P.uniform2i = function (l, x, y) { if (l !== null) g.__mv_glUniform2i(this.__gl, l, x, y); };
  P.uniform1fv = function (l, v) { if (l !== null) g.__mv_glUniformfv(this.__gl, 1, l, v); };
  P.uniform2fv = function (l, v) { if (l !== null) g.__mv_glUniformfv(this.__gl, 2, l, v); };
  P.uniform3fv = function (l, v) { if (l !== null) g.__mv_glUniformfv(this.__gl, 3, l, v); };
  P.uniform4fv = function (l, v) { if (l !== null) g.__mv_glUniformfv(this.__gl, 4, l, v); };
  P.uniform1iv = function (l, v) { if (l !== null) g.__mv_glUniformiv(this.__gl, 1, l, v); };
  // ivec3/ivec4 scalars. PIXI generates these setters for `ivec3`/`ivec4` (and
  // `bvec3`/`bvec4`) uniforms, so a shader declaring one would otherwise throw
  // mid-render. Routed through the vector upload rather than stubbed, since a
  // silently-unset uniform is a wrong picture, not a missing feature.
  P.uniform3i = function (l, x, y, z) { if (l !== null) g.__mv_glUniformiv(this.__gl, 3, l, [x, y, z]); };
  P.uniform4i = function (l, x, y, z, w) { if (l !== null) g.__mv_glUniformiv(this.__gl, 4, l, [x, y, z, w]); };
  P.uniform2iv = function (l, v) { if (l !== null) g.__mv_glUniformiv(this.__gl, 2, l, v); };
  P.uniform3iv = function (l, v) { if (l !== null) g.__mv_glUniformiv(this.__gl, 3, l, v); };
  P.uniform4iv = function (l, v) { if (l !== null) g.__mv_glUniformiv(this.__gl, 4, l, v); };
  P.uniformMatrix2fv = function (l, t, v) { if (l !== null) g.__mv_glUniformMatrix(this.__gl, 2, l, t ? 1 : 0, v); };
  P.uniformMatrix3fv = function (l, t, v) { if (l !== null) g.__mv_glUniformMatrix(this.__gl, 3, l, t ? 1 : 0, v); };
  P.uniformMatrix4fv = function (l, t, v) { if (l !== null) g.__mv_glUniformMatrix(this.__gl, 4, l, t ? 1 : 0, v); };

  // Textures.
  P.createTexture = function () { return g.__mv_glCreateTexture(this.__gl); };
  P.bindTexture = function (t, tex) { g.__mv_glBindTexture(this.__gl, t, tex || 0); };
  P.texParameteri = function (t, p, v) { g.__mv_glTexParameteri(this.__gl, t, p, v); };
  P.texParameterf = function (t, p, v) { g.__mv_glTexParameteri(this.__gl, t, p, v | 0); };
  P.texImage2D = function (target, level, internalformat, a, b, c, d, e, f) {
    if (arguments.length >= 9) {
      // (target, level, internalformat, w, h, border, format, type, pixels)
      g.__mv_glTexImage2D(this.__gl, target, level, internalformat, a, b, c, d, e, f);
    } else {
      // (target, level, internalformat, format, type, source)
      var src = c;
      if (src && src.__h !== undefined) {
        g.__mv_glTexImage2DCanvas(this.__gl, target, level, internalformat, a, b, src.__h);
      } else if (src && src.canvas && src.canvas.__h !== undefined) {
        g.__mv_glTexImage2DCanvas(this.__gl, target, level, internalformat, a, b, src.canvas.__h);
      }
      // Image elements route through the same __h canvas handle (they are
      // backed by a canvas, see mvcanvas.cxx); UNPACK_FLIP_Y_WEBGL is
      // honoured on this path the same as UNPACK_PREMULTIPLY_ALPHA_WEBGL --
      // see js_gl_pixel_storei's comment and js_gl_tex_image_2d_canvas.
    }
  };
  // texSubImage2D has the same two overloads as texImage2D, one argument
  // shorter (there is no internalformat or border): the 9-argument sized form
  // with a typed array, and the 7-argument form taking a canvas/image source.
  // Both matter — see the native side; a no-op here loses every texture update
  // that follows the first upload, which is most of what MZ draws.
  P.texSubImage2D = function (target, level, xoff, yoff, a, b, c, d, e) {
    if (arguments.length >= 9) {
      // (target, level, xoffset, yoffset, w, h, format, type, pixels)
      g.__mv_glTexSubImage2D(this.__gl, target, level, xoff, yoff, a, b, c, d, e);
    } else {
      // (target, level, xoffset, yoffset, format, type, source)
      var src = c;
      if (src && src.__h !== undefined) {
        g.__mv_glTexSubImage2DCanvas(this.__gl, target, level, xoff, yoff, a, b, src.__h);
      } else if (src && src.canvas && src.canvas.__h !== undefined) {
        g.__mv_glTexSubImage2DCanvas(this.__gl, target, level, xoff, yoff, a, b, src.canvas.__h);
      }
    }
  };
  P.generateMipmap = function (t) { g.__mv_glGenerateMipmap(this.__gl, t); };
  P.deleteTexture = function (t) { g.__mv_glDeleteTexture(this.__gl, t); };

  // Framebuffers (renderbuffers are stubbed until M6.3c needs depth targets).
  P.createFramebuffer = function () { return g.__mv_glCreateFramebuffer(this.__gl); };
  P.bindFramebuffer = function (t, f) { g.__mv_glBindFramebuffer(this.__gl, t, f || 0); };
  P.framebufferTexture2D = function (t, a, tt, tex, l) { g.__mv_glFramebufferTexture2D(this.__gl, t, a, tt, tex || 0, l); };
  P.checkFramebufferStatus = function (t) { return g.__mv_glCheckFramebufferStatus(this.__gl, t); };
  P.deleteFramebuffer = function (f) { g.__mv_glDeleteFramebuffer(this.__gl, f); };
  // Renderbuffers back the depth/stencil a render texture's framebuffer needs.
  // MZ reaches these through rmmz's WindowLayer, which asks PIXI for a stencil
  // on whatever framebuffer is current — always a filter target, since every
  // scene carries a ColorFilter — and then masks each window against the ones
  // in front of it. See the native side for the two WebGL1 enums translated.
  P.createRenderbuffer = function () { return g.__mv_glCreateRenderbuffer(this.__gl); };
  P.bindRenderbuffer = function (t, r) { g.__mv_glBindRenderbuffer(this.__gl, t, r || 0); };
  P.renderbufferStorage = function (t, f, w, h) { g.__mv_glRenderbufferStorage(this.__gl, t, f, w, h); };
  P.framebufferRenderbuffer = function (t, a, rt, r) { g.__mv_glFramebufferRenderbuffer(this.__gl, t, a, rt, r || 0); };
  P.deleteRenderbuffer = function (r) { g.__mv_glDeleteRenderbuffer(this.__gl, r); };

  // Draw & read.
  P.drawArrays = function (m, f, c) { g.__mv_glDrawArrays(this.__gl, m, f, c); };
  P.drawElements = function (m, c, t, o) { g.__mv_glDrawElements(this.__gl, m, c, t, o); };
  P.readPixels = function (x, y, w, h, f, t, px) { g.__mv_glReadPixels(this.__gl, x, y, w, h, f, t, px); };
  P.finish = function () { g.__mv_glFinish(this.__gl); };
  P.flush = function () { g.__mv_glFlush(this.__gl); };

  // Queries.
  P.getParameter = function (p) {
    if (p === K.VERSION || p === K.SHADING_LANGUAGE_VERSION || p === K.VENDOR || p === K.RENDERER)
      return g.__mv_glGetString(this.__gl, p);
    if (p === K.MAX_VIEWPORT_DIMS) return new Int32Array([4096, 4096]);
    if (p === K.VIEWPORT) return new Int32Array([0, 0, this.drawingBufferWidth, this.drawingBufferHeight]);
    if (p === K.SCISSOR_BOX) return new Int32Array([0, 0, this.drawingBufferWidth, this.drawingBufferHeight]);
    if (p === K.ALIASED_LINE_WIDTH_RANGE || p === K.ALIASED_POINT_SIZE_RANGE) return new Float32Array([1, 1]);
    return g.__mv_glGetIntParam(this.__gl, p);
  };
  P.getError = function () { return g.__mv_glGetError(this.__gl); };
  P.isContextLost = function () { return false; };
  P.getContextAttributes = function () {
    return { alpha: true, depth: true, stencil: true, antialias: false,
             premultipliedAlpha: true, preserveDrawingBuffer: false,
             failIfMajorPerformanceCaveat: false };
  };
  // Extensions: the two PIXI's GeometrySystem checks for a fast path
  // (OES_vertex_array_object, ANGLE_instanced_arrays -- see the native-side
  // comment above js_gl_ext_vao_available) plus OES_element_index_uint, which
  // PIXI's ContextSystem.getExtensions reads unconditionally into
  // `context.extensions.uint32ElementIndex` and GeometrySystem.contextChange
  // turns into `canUseUInt32ElementIndex` -- false without it, which caps
  // every index buffer at 65536 vertices (Uint16Array) and forces smaller,
  // more numerous draw calls than a real browser would need. Unlike the other
  // two this needs no native entry points at all: WebGL1 gates
  // `UNSIGNED_INT` in drawElements/element buffers behind this extension, but
  // our backend is GLES 3.0+ core throughout (see mvgl.cxx's bind_context),
  // where that type is unconditionally legal -- so this is a pure
  // capability flag, always on, with no methods to wire up (confirmed against
  // a real MZ game: without it, the boot log warns "does not support 32 index
  // buffer"). Everything else PIXI probes (anisotropy, float textures, ...)
  // still degrades gracefully to null; PIXI handles a missing extension for
  // those the same way it always has. Cached per context in `this._ext` so
  // repeat calls return the same object, as the WebGL spec requires and
  // PIXI's own caching (`context.extensions.*`) expects.
  P.getExtension = function (name) {
    if (Object.prototype.hasOwnProperty.call(this._ext, name)) {
      return this._ext[name];
    }
    var gl = this.__gl;
    var ext = null;
    if (name === 'OES_vertex_array_object' && g.__mv_glExtVaoAvailable(gl)) {
      ext = {
        createVertexArrayOES: function () { return g.__mv_glExtCreateVertexArray(gl); },
        bindVertexArrayOES: function (a) { g.__mv_glExtBindVertexArray(gl, a || 0); },
        deleteVertexArrayOES: function (a) { g.__mv_glExtDeleteVertexArray(gl, a || 0); },
        isVertexArrayOES: function (a) { return g.__mv_glExtIsVertexArray(gl, a || 0); },
      };
    } else if (name === 'ANGLE_instanced_arrays' && g.__mv_glExtInstancedAvailable(gl)) {
      ext = {
        vertexAttribDivisorANGLE: function (i, d) { g.__mv_glExtVertexAttribDivisor(gl, i, d); },
        drawArraysInstancedANGLE: function (m, f, c, p) { g.__mv_glExtDrawArraysInstanced(gl, m, f, c, p); },
        drawElementsInstancedANGLE: function (m, c, t, o, p) { g.__mv_glExtDrawElementsInstanced(gl, m, c, t, o, p); },
      };
    } else if (name === 'OES_element_index_uint') {
      ext = {};
    }
    this._ext[name] = ext;
    return ext;
  };
  P.getSupportedExtensions = function () {
    var out = ['OES_element_index_uint'];
    if (g.__mv_glExtVaoAvailable(this.__gl)) out.push('OES_vertex_array_object');
    if (g.__mv_glExtInstancedAvailable(this.__gl)) out.push('ANGLE_instanced_arrays');
    return out;
  };

  g.WebGLRenderingContext = WebGLRenderingContext;
})(typeof globalThis !== 'undefined' ? globalThis : this);
)MVJS";

}  // namespace

// Read back the WebGL context's FBO as top-down RGBA8 (see mvhost.hxx). The MZ
// present path copies this onto the on-screen RGSS::Bitmap each frame, the way
// mv_canvas_pixels serves MV's Canvas2D main canvas.
const uint8_t* mv_webgl_pixels(int handle, int* w, int* h) {
  mvgl::Context* c = bind(handle);
  if (!c)
    return nullptr;
  return mvgl::pixels(c, w, h);
}

// See mvhost.hxx's own comment on why mvefk.cxx (a different translation
// unit) needs this rather than assuming its own EGL context is already
// current: `bind` here is the exact same handle->context resolution and
// make-current every other `__mv_gl*` call goes through.
bool mv_webgl_make_current(int handle) {
  return bind(handle) != nullptr;
}

// Install the WebGL bridge: the __mv_gl* natives and the WebGLRenderingContext
// prototype. Called once after the Canvas2D bridge (mvjs.cxx). The canvas
// shim's getContext("webgl") gates on __mv_glCreate existing, so on a build
// without the EGL backend (the #else below) getContext stays null.
void mv_install_webgl(JSContext* ctx) {
  JSValue g = JS_GetGlobalObject(ctx);
  reg(ctx, g, "__mv_glCreate", js_gl_create, 2);
  reg(ctx, g, "__mv_glResize", js_gl_resize, 3);
  reg(ctx, g, "__mv_glViewport", js_gl_viewport, 5);
  reg(ctx, g, "__mv_glScissor", js_gl_scissor, 5);
  reg(ctx, g, "__mv_glClearColor", js_gl_clear_color, 5);
  reg(ctx, g, "__mv_glClear", js_gl_clear, 2);
  reg(ctx, g, "__mv_glEnable", js_gl_enable, 2);
  reg(ctx, g, "__mv_glDisable", js_gl_disable, 2);
  reg(ctx, g, "__mv_glBlendFunc", js_gl_blend_func, 3);
  reg(ctx, g, "__mv_glBlendFuncSeparate", js_gl_blend_func_separate, 5);
  reg(ctx, g, "__mv_glStencilFunc", js_gl_stencil_func, 4);
  reg(ctx, g, "__mv_glStencilOp", js_gl_stencil_op, 4);
  reg(ctx, g, "__mv_glStencilMask", js_gl_stencil_mask, 2);
  reg(ctx, g, "__mv_glClearStencil", js_gl_clear_stencil, 2);
  reg(ctx, g, "__mv_glBlendEquation", js_gl_blend_equation, 2);
  reg(ctx, g, "__mv_glBlendEquationSeparate", js_gl_blend_equation_separate, 3);
  reg(ctx, g, "__mv_glDepthFunc", js_gl_depth_func, 2);
  reg(ctx, g, "__mv_glDepthMask", js_gl_depth_mask, 2);
  reg(ctx, g, "__mv_glColorMask", js_gl_color_mask, 5);
  reg(ctx, g, "__mv_glCullFace", js_gl_cull_face, 2);
  reg(ctx, g, "__mv_glFrontFace", js_gl_front_face, 2);
  reg(ctx, g, "__mv_glPixelStorei", js_gl_pixel_storei, 3);
  reg(ctx, g, "__mv_glActiveTexture", js_gl_active_texture, 2);
  reg(ctx, g, "__mv_glCreateShader", js_gl_create_shader, 2);
  reg(ctx, g, "__mv_glShaderSource", js_gl_shader_source, 3);
  reg(ctx, g, "__mv_glCompileShader", js_gl_compile_shader, 2);
  reg(ctx, g, "__mv_glGetShaderParameter", js_gl_get_shader_parameter, 3);
  reg(ctx, g, "__mv_glGetShaderInfoLog", js_gl_get_shader_info_log, 2);
  reg(ctx, g, "__mv_glDeleteShader", js_gl_delete_shader, 2);
  reg(ctx, g, "__mv_glCreateProgram", js_gl_create_program, 1);
  reg(ctx, g, "__mv_glAttachShader", js_gl_attach_shader, 3);
  reg(ctx, g, "__mv_glBindAttribLocation", js_gl_bind_attrib_location, 4);
  reg(ctx, g, "__mv_glLinkProgram", js_gl_link_program, 2);
  reg(ctx, g, "__mv_glGetProgramParameter", js_gl_get_program_parameter, 3);
  reg(ctx, g, "__mv_glGetProgramInfoLog", js_gl_get_program_info_log, 2);
  reg(ctx, g, "__mv_glUseProgram", js_gl_use_program, 2);
  reg(ctx, g, "__mv_glDeleteProgram", js_gl_delete_program, 2);
  reg(ctx, g, "__mv_glGetAttribLocation", js_gl_get_attrib_location, 3);
  reg(ctx, g, "__mv_glGetUniformLocation", js_gl_get_uniform_location, 3);
  reg(ctx, g, "__mv_glGetActiveUniform", js_gl_get_active_uniform, 3);
  reg(ctx, g, "__mv_glGetActiveAttrib", js_gl_get_active_attrib, 3);
  reg(ctx, g, "__mv_glCreateBuffer", js_gl_create_buffer, 1);
  reg(ctx, g, "__mv_glBindBuffer", js_gl_bind_buffer, 3);
  reg(ctx, g, "__mv_glBufferData", js_gl_buffer_data, 4);
  reg(ctx, g, "__mv_glBufferSubData", js_gl_buffer_sub_data, 4);
  reg(ctx, g, "__mv_glDeleteBuffer", js_gl_delete_buffer, 2);
  reg(ctx, g, "__mv_glEnableVertexAttribArray",
      js_gl_enable_vertex_attrib_array, 2);
  reg(ctx, g, "__mv_glDisableVertexAttribArray",
      js_gl_disable_vertex_attrib_array, 2);
  reg(ctx, g, "__mv_glVertexAttribPointer", js_gl_vertex_attrib_pointer, 7);
  reg(ctx, g, "__mv_glUniform1f", js_gl_uniform1f, 3);
  reg(ctx, g, "__mv_glUniform2f", js_gl_uniform2f, 4);
  reg(ctx, g, "__mv_glUniform3f", js_gl_uniform3f, 5);
  reg(ctx, g, "__mv_glUniform4f", js_gl_uniform4f, 6);
  reg(ctx, g, "__mv_glUniform1i", js_gl_uniform1i, 3);
  reg(ctx, g, "__mv_glUniform2i", js_gl_uniform2i, 4);
  reg(ctx, g, "__mv_glUniformfv", js_gl_uniform_fv, 4);
  reg(ctx, g, "__mv_glUniformiv", js_gl_uniform_iv, 4);
  reg(ctx, g, "__mv_glUniformMatrix", js_gl_uniform_matrix, 5);
  reg(ctx, g, "__mv_glCreateTexture", js_gl_create_texture, 1);
  reg(ctx, g, "__mv_glBindTexture", js_gl_bind_texture, 3);
  reg(ctx, g, "__mv_glTexParameteri", js_gl_tex_parameteri, 4);
  reg(ctx, g, "__mv_glTexImage2D", js_gl_tex_image_2d, 10);
  reg(ctx, g, "__mv_glTexImage2DCanvas", js_gl_tex_image_2d_canvas, 7);
  reg(ctx, g, "__mv_glTexSubImage2D", js_gl_tex_sub_image_2d, 10);
  reg(ctx, g, "__mv_glTexSubImage2DCanvas", js_gl_tex_sub_image_2d_canvas, 8);
  reg(ctx, g, "__mv_glGenerateMipmap", js_gl_generate_mipmap, 2);
  reg(ctx, g, "__mv_glDeleteTexture", js_gl_delete_texture, 2);
  reg(ctx, g, "__mv_glCreateFramebuffer", js_gl_create_framebuffer, 1);
  reg(ctx, g, "__mv_glBindFramebuffer", js_gl_bind_framebuffer, 3);
  reg(ctx, g, "__mv_glFramebufferTexture2D", js_gl_framebuffer_texture_2d, 6);
  reg(ctx, g, "__mv_glCreateRenderbuffer", js_gl_create_renderbuffer, 1);
  reg(ctx, g, "__mv_glBindRenderbuffer", js_gl_bind_renderbuffer, 3);
  reg(ctx, g, "__mv_glRenderbufferStorage", js_gl_renderbuffer_storage, 5);
  reg(ctx, g, "__mv_glFramebufferRenderbuffer", js_gl_framebuffer_renderbuffer,
      5);
  reg(ctx, g, "__mv_glDeleteRenderbuffer", js_gl_delete_renderbuffer, 2);
  reg(ctx, g, "__mv_glCheckFramebufferStatus", js_gl_check_framebuffer_status,
      2);
  reg(ctx, g, "__mv_glDeleteFramebuffer", js_gl_delete_framebuffer, 2);
  reg(ctx, g, "__mv_glDrawArrays", js_gl_draw_arrays, 4);
  reg(ctx, g, "__mv_glDrawElements", js_gl_draw_elements, 5);
  reg(ctx, g, "__mv_glReadPixels", js_gl_read_pixels, 8);
  reg(ctx, g, "__mv_glGetIntParam", js_gl_get_int_param, 2);
  reg(ctx, g, "__mv_glGetString", js_gl_get_string, 2);
  reg(ctx, g, "__mv_glGetError", js_gl_get_error, 1);
  reg(ctx, g, "__mv_glFinish", js_gl_finish, 1);
  reg(ctx, g, "__mv_glFlush", js_gl_flush, 1);
  reg(ctx, g, "__mv_glExtVaoAvailable", js_gl_ext_vao_available, 1);
  reg(ctx, g, "__mv_glExtCreateVertexArray", js_gl_ext_create_vertex_array, 1);
  reg(ctx, g, "__mv_glExtBindVertexArray", js_gl_ext_bind_vertex_array, 2);
  reg(ctx, g, "__mv_glExtDeleteVertexArray", js_gl_ext_delete_vertex_array, 2);
  reg(ctx, g, "__mv_glExtIsVertexArray", js_gl_ext_is_vertex_array, 2);
  reg(ctx, g, "__mv_glExtInstancedAvailable", js_gl_ext_instanced_available, 1);
  reg(ctx, g, "__mv_glExtVertexAttribDivisor", js_gl_ext_vertex_attrib_divisor,
      3);
  reg(ctx, g, "__mv_glExtDrawArraysInstanced", js_gl_ext_draw_arrays_instanced,
      5);
  reg(ctx, g, "__mv_glExtDrawElementsInstanced",
      js_gl_ext_draw_elements_instanced, 6);
  JS_FreeValue(ctx, g);

  JSValue r = JS_Eval(ctx, kWebGLPreamble, std::strlen(kWebGLPreamble),
                      "<mv-webgl-preamble>", JS_EVAL_TYPE_GLOBAL);
  JS_FreeValue(ctx, r);
}

#else  // no EGL/GLES2 backend (Emscripten, or headers absent)

// No native GL: install nothing. The canvas shim's getContext("webgl") gates on
// __mv_glCreate, so it keeps returning null and PIXI/MZ reports WebGL absent.
void mv_install_webgl(JSContext*) {}

// No GL backend: there is no WebGL frame to present.
const uint8_t* mv_webgl_pixels(int, int*, int*) {
  return nullptr;
}

// No GL backend: no context to make current (mvefk's own real branch is
// equally absent in this build, so this is never actually called).
bool mv_webgl_make_current(int) {
  return false;
}

#endif
