// EGL surfaceless off-screen GLES2 context for the WebGL path (milestone
// M6.3a). See mvgl.hxx for why this exists and how it fits the software
// renderer.

#include "mvgl.hxx"

// The backend needs EGL + GLES2 headers. The Emscripten build renders MZ
// through the browser's own WebGL, and some environments (e.g. darwin) ship
// neither header — in both cases mvgl compiles to inert stubs and `available()`
// reports false. The apt and nix builds both provide the headers (libEGL /
// libGLESv2 via mesa + libglvnd), so the real backend is what compiles there.
// `__has_include` makes this a compile-time decision with no build-system
// probing.
//
// This used to sit on OSMesa, but Mesa removed the OSMesa frontend (gone from
// mesa 26.1, so nixpkgs 26.05 ships no libOSMesa). EGL with the surfaceless
// platform (EGL_MESA_platform_surfaceless) is the supported way to get an
// off-screen GLES2 context on modern Mesa: it renders through llvmpipe into an
// FBO with no GPU or display, matching the software LVGL pipeline exactly as
// OSMesa did.
#if !defined(__EMSCRIPTEN__) && __has_include(<EGL/egl.h>) && \
    __has_include(<GLES2/gl2.h>)
#define MVJS_HAVE_EGL 1

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

// ES3 renderbuffer/attachment enums the base <GLES2/gl2.h> may not declare. The
// llvmpipe context we create is ES3-capable, so these are valid at runtime;
// define them defensively for builds whose GLES2 header predates ES3.
#ifndef GL_RGBA8
#define GL_RGBA8 0x8058
#endif
#ifndef GL_DEPTH24_STENCIL8
#define GL_DEPTH24_STENCIL8 0x88F0
#endif
#ifndef GL_DEPTH_STENCIL_ATTACHMENT
#define GL_DEPTH_STENCIL_ATTACHMENT 0x821A
#endif
#ifndef EGL_OPENGL_ES3_BIT
#define EGL_OPENGL_ES3_BIT 0x00000040
#endif
#ifndef EGL_PLATFORM_SURFACELESS_MESA
#define EGL_PLATFORM_SURFACELESS_MESA 0x31DD
#endif

namespace mvgl {

namespace {

// Log a one-line reason to stderr, tagged like the rest of the maker runtime.
void warn(const char* what, const char* detail) {
  std::fprintf(stderr, "[MZ-GL] %s%s%s\n", what, detail ? ": " : "",
               detail ? detail : "");
}

// Compile a GLES2 shader, logging and returning 0 on failure.
GLuint compile(GLenum type, const char* src) {
  GLuint sh = glCreateShader(type);
  glShaderSource(sh, 1, &src, nullptr);
  glCompileShader(sh);
  GLint ok = GL_FALSE;
  glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char log[1024];
    GLsizei n = 0;
    glGetShaderInfoLog(sh, sizeof(log), &n, log);
    warn(type == GL_VERTEX_SHADER ? "vertex shader failed to compile"
                                  : "fragment shader failed to compile",
         n ? log : "no log");
    glDeleteShader(sh);
    return 0;
  }
  return sh;
}

// Open the off-screen display. Prefer the surfaceless Mesa platform (no window
// system, no device node needed) via the 1.5 core entry point, then the EXT
// entry point, then plain eglGetDisplay as a last resort.
EGLDisplay open_display() {
#if defined(EGL_VERSION_1_5)
  EGLDisplay d = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA,
                                       EGL_DEFAULT_DISPLAY, nullptr);
  if (d != EGL_NO_DISPLAY)
    return d;
#endif
  auto get_platform_display = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
      eglGetProcAddress("eglGetPlatformDisplayEXT"));
  if (get_platform_display) {
    EGLDisplay d = get_platform_display(EGL_PLATFORM_SURFACELESS_MESA,
                                        EGL_DEFAULT_DISPLAY, nullptr);
    if (d != EGL_NO_DISPLAY)
      return d;
  }
  return eglGetDisplay(EGL_DEFAULT_DISPLAY);
}

// Pick an RGBA8 + depth24/stencil8 config. Ask for an ES3-renderable one first
// (what we create), falling back to ES2 for a driver that only advertises ES2
// configs; the ES 1.00 shaders PIXI uses run on either.
bool choose_config(EGLDisplay dpy, EGLConfig* out) {
  const EGLint es_bits[] = {EGL_OPENGL_ES3_BIT, EGL_OPENGL_ES2_BIT};
  for (EGLint bit : es_bits) {
    const EGLint attribs[] = {EGL_SURFACE_TYPE,
                              EGL_PBUFFER_BIT,
                              EGL_RENDERABLE_TYPE,
                              bit,
                              EGL_RED_SIZE,
                              8,
                              EGL_GREEN_SIZE,
                              8,
                              EGL_BLUE_SIZE,
                              8,
                              EGL_ALPHA_SIZE,
                              8,
                              EGL_DEPTH_SIZE,
                              24,
                              EGL_STENCIL_SIZE,
                              8,
                              EGL_NONE};
    EGLint n = 0;
    if (eglChooseConfig(dpy, attribs, out, 1, &n) && n >= 1)
      return true;
  }
  return false;
}

}  // namespace

struct Context {
  EGLDisplay dpy = EGL_NO_DISPLAY;
  EGLContext egl = EGL_NO_CONTEXT;
  GLuint fbo = 0;
  GLuint color_rb = 0;  // RGBA8 colour renderbuffer (the render target)
  GLuint ds_rb = 0;     // packed depth24/stencil8 renderbuffer
  int w = 0;
  int h = 0;
  std::vector<std::uint8_t> buffer;   // RGBA8, bottom-up (glReadPixels order)
  std::vector<std::uint8_t> flipped;  // RGBA8, top-down (present order)
};

Context* create(int width, int height) {
  if (width <= 0 || height <= 0) {
    warn("create: non-positive dimensions", nullptr);
    return nullptr;
  }

  EGLDisplay dpy = open_display();
  if (dpy == EGL_NO_DISPLAY) {
    warn("create: no EGL display (surfaceless platform unavailable)", nullptr);
    return nullptr;
  }
  EGLint major = 0, minor = 0;
  if (!eglInitialize(dpy, &major, &minor)) {
    warn("create: eglInitialize failed", nullptr);
    return nullptr;
  }
  if (!eglBindAPI(EGL_OPENGL_ES_API)) {
    warn("create: eglBindAPI(EGL_OPENGL_ES_API) failed", nullptr);
    return nullptr;
  }

  EGLConfig cfg = nullptr;
  if (!choose_config(dpy, &cfg)) {
    warn("create: eglChooseConfig found no RGBA8 config", nullptr);
    return nullptr;
  }

  // Request ES 3.0 (a comfortable superset of the ES 2.0 PIXI needs, and what
  // llvmpipe advertises), falling back to an ES 2.0 context. The rendering only
  // uses ES2/ES 1.00-shader features, so either is fine.
  const EGLint es3_attribs[] = {EGL_CONTEXT_MAJOR_VERSION, 3,
                                EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE};
  EGLContext egl = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, es3_attribs);
  if (egl == EGL_NO_CONTEXT) {
    const EGLint es2_attribs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    egl = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, es2_attribs);
  }
  if (egl == EGL_NO_CONTEXT) {
    warn("create: eglCreateContext failed", nullptr);
    return nullptr;
  }

  // Surfaceless: no draw/read surface, an FBO is the render target instead.
  if (!eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, egl)) {
    warn("create: eglMakeCurrent(surfaceless) failed", nullptr);
    eglDestroyContext(dpy, egl);
    return nullptr;
  }

  Context* ctx = new Context();
  ctx->dpy = dpy;
  ctx->egl = egl;
  ctx->w = width;
  ctx->h = height;
  const size_t bytes = static_cast<size_t>(width) * height * 4;
  ctx->buffer.assign(bytes, 0);
  ctx->flipped.assign(bytes, 0);

  glGenFramebuffers(1, &ctx->fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, ctx->fbo);
  glGenRenderbuffers(1, &ctx->color_rb);
  glBindRenderbuffer(GL_RENDERBUFFER, ctx->color_rb);
  glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, width, height);
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                            GL_RENDERBUFFER, ctx->color_rb);
  glGenRenderbuffers(1, &ctx->ds_rb);
  glBindRenderbuffer(GL_RENDERBUFFER, ctx->ds_rb);
  glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, width, height);
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT,
                            GL_RENDERBUFFER, ctx->ds_rb);
  if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
    warn("create: framebuffer incomplete", nullptr);
    destroy(ctx);
    return nullptr;
  }
  glViewport(0, 0, width, height);
  return ctx;
}

void destroy(Context* ctx) {
  if (!ctx)
    return;
  if (ctx->dpy != EGL_NO_DISPLAY && ctx->egl != EGL_NO_CONTEXT) {
    eglMakeCurrent(ctx->dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx->egl);
    if (ctx->fbo)
      glDeleteFramebuffers(1, &ctx->fbo);
    if (ctx->color_rb)
      glDeleteRenderbuffers(1, &ctx->color_rb);
    if (ctx->ds_rb)
      glDeleteRenderbuffers(1, &ctx->ds_rb);
    eglMakeCurrent(ctx->dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(ctx->dpy, ctx->egl);
    // The display is process-shared and refcounted by eglInitialize; leave it
    // initialised rather than tearing it down under any other live context.
  }
  delete ctx;
}

bool make_current(Context* ctx) {
  if (!ctx || ctx->dpy == EGL_NO_DISPLAY || ctx->egl == EGL_NO_CONTEXT)
    return false;
  if (!eglMakeCurrent(ctx->dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx->egl))
    return false;
  // A fresh make-current binds the default framebuffer; rebind ours (there is
  // no window-system surface) so draws and readback hit the render target.
  glBindFramebuffer(GL_FRAMEBUFFER, ctx->fbo);
  glViewport(0, 0, ctx->w, ctx->h);
  return true;
}

const std::uint8_t* pixels(Context* ctx, int* out_w, int* out_h) {
  if (!ctx)
    return nullptr;
  if (out_w)
    *out_w = ctx->w;
  if (out_h)
    *out_h = ctx->h;
  if (!make_current(ctx))
    return nullptr;
  glReadPixels(0, 0, ctx->w, ctx->h, GL_RGBA, GL_UNSIGNED_BYTE,
               ctx->buffer.data());
  // glReadPixels' origin is bottom-left; flip to top-down so `pixels` (and
  // PIXI's own y-flip conventions) line up with the RGSS::Bitmap surface.
  const int stride = ctx->w * 4;
  for (int y = 0; y < ctx->h; ++y)
    std::memcpy(
        ctx->flipped.data() + static_cast<size_t>(y) * stride,
        ctx->buffer.data() + static_cast<size_t>(ctx->h - 1 - y) * stride,
        stride);
  return ctx->flipped.data();
}

unsigned default_framebuffer(Context* ctx) {
  return ctx ? ctx->fbo : 0u;
}

bool smoke_test(std::uint8_t out_rgba[4]) {
  const int W = 64, H = 64;
  Context* ctx = create(W, H);
  if (!ctx)
    return false;

  // Report what backend we actually got — invaluable when a CI runner's Mesa
  // differs from the dev box.
  std::fprintf(
      stderr, "[MZ-GL] GL_VERSION=%s RENDERER=%s GLSL=%s\n",
      reinterpret_cast<const char*>(glGetString(GL_VERSION)),
      reinterpret_cast<const char*>(glGetString(GL_RENDERER)),
      reinterpret_cast<const char*>(glGetString(GL_SHADING_LANGUAGE_VERSION)));

  // PIXI v5's WebGL1 shaders are GLSL ES 1.00; use the same dialect here so the
  // self-test proves the exact compile path the engine will hit.
  const char* vs =
      "#version 100\n"
      "attribute vec2 aPos;\n"
      "void main(){ gl_Position = vec4(aPos, 0.0, 1.0); }\n";
  const char* fs =
      "#version 100\n"
      "precision mediump float;\n"
      "void main(){ gl_FragColor = vec4(0.0, 1.0, 0.0, 1.0); }\n";

  bool ok = false;
  GLuint v = compile(GL_VERTEX_SHADER, vs);
  GLuint f = compile(GL_FRAGMENT_SHADER, fs);
  GLuint prog = 0;
  if (v && f) {
    prog = glCreateProgram();
    glAttachShader(prog, v);
    glAttachShader(prog, f);
    glBindAttribLocation(prog, 0, "aPos");
    glLinkProgram(prog);
    GLint linked = GL_FALSE;
    glGetProgramiv(prog, GL_LINK_STATUS, &linked);
    if (!linked) {
      char log[1024];
      GLsizei n = 0;
      glGetProgramInfoLog(prog, sizeof(log), &n, log);
      warn("program failed to link", n ? log : "no log");
    } else {
      glUseProgram(prog);
      glViewport(0, 0, W, H);
      glClearColor(0.2f, 0.0f, 0.0f, 1.0f);
      glClear(GL_COLOR_BUFFER_BIT);
      // A single triangle that covers the whole viewport.
      const float tri[] = {-1.f, -1.f, 3.f, -1.f, -1.f, 3.f};
      GLuint vbo = 0;
      glGenBuffers(1, &vbo);
      glBindBuffer(GL_ARRAY_BUFFER, vbo);
      glBufferData(GL_ARRAY_BUFFER, sizeof(tri), tri, GL_STATIC_DRAW);
      glEnableVertexAttribArray(0);
      glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
      glDrawArrays(GL_TRIANGLES, 0, 3);
      glFinish();

      std::uint8_t px[4] = {0, 0, 0, 0};
      glReadPixels(W / 2, H / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
      glDeleteBuffers(1, &vbo);
      // The whole viewport is the green triangle: centre must be green.
      ok = px[1] > 200 && px[0] < 60 && px[2] < 60;
      if (ok && out_rgba)
        std::memcpy(out_rgba, px, 4);
      if (!ok)
        std::fprintf(stderr,
                     "[MZ-GL] smoke_test unexpected centre pixel %d,%d,%d,%d\n",
                     px[0], px[1], px[2], px[3]);
    }
  }

  if (prog)
    glDeleteProgram(prog);
  if (v)
    glDeleteShader(v);
  if (f)
    glDeleteShader(f);
  destroy(ctx);
  return ok;
}

bool available() {
  return true;
}

}  // namespace mvgl

#else  // no EGL/GLES2 (Emscripten, or a build without the headers)

// Inert stubs so the shared binding (MV::GL) still links; `available()` reports
// false so callers (and the gl_test spec) skip the GL path cleanly.
namespace mvgl {
Context* create(int, int) {
  return nullptr;
}
void destroy(Context*) {}
bool make_current(Context*) {
  return false;
}
const std::uint8_t* pixels(Context*, int*, int*) {
  return nullptr;
}
unsigned default_framebuffer(Context*) {
  return 0u;
}
bool smoke_test(std::uint8_t[4]) {
  return false;
}
bool available() {
  return false;
}
}  // namespace mvgl

#endif
