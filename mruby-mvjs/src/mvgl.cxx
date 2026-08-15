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
#include <string>
#include <vector>

// log_bridge_write_stderr (mruby-rgss/src/log_bridge.cxx), so warn() below
// also reaches ng-log; see include/terminal.hxx.
#include "terminal.hxx"

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
#ifndef EGL_PLATFORM_DEVICE_EXT
#define EGL_PLATFORM_DEVICE_EXT 0x313F
#endif

namespace mvgl {

namespace {

// Log a one-line reason to stderr, tagged like the rest of the maker runtime.
void warn(const char* what, const char* detail) {
  const std::string msg = std::string("[MZ-GL] ") + what +
                          (detail ? ": " : "") + (detail ? detail : "");
  log_bridge_write_stderr(msg.c_str());
}

// Pin EGL/GLES to the pure-software surfaceless path for the duration of an EGL
// call, restoring the environment after. Our GL is entirely off-screen
// (surfaceless llvmpipe + an FBO) and never needs the window system, so this
// forces `EGL_PLATFORM=surfaceless` / `GALLIUM_DRIVER=llvmpipe` /
// `LIBGL_ALWAYS_SOFTWARE=1` and hides `DISPLAY`/`XAUTHORITY`. NOTE this is
// belt-and-braces, not a guarantee of no-X: when an X server is actually
// reachable, Mesa still dispatches even a surfaceless `eglMakeCurrent` through
// GLX and is denied (`X BadAccess` on `X_GLXMakeCurrent`) — hiding the env
// alone does not stop it. The real off-screen guarantee comes from running with
// no X server at all (the headless `gl_test`, and the MZ boot smoke via SDL's
// `dummy` video driver), which is where this binds cleanly. Safe: nothing else
// in the process uses EGL/GLX (LVGL's SDL backend is the software renderer),
// and every variable is restored the moment the EGL call returns.
class ScopedSoftwareEGL {
 public:
  ScopedSoftwareEGL() {
    hide("DISPLAY");
    hide("XAUTHORITY");
    force("EGL_PLATFORM", "surfaceless");
    force("GALLIUM_DRIVER", "llvmpipe");
    force("LIBGL_ALWAYS_SOFTWARE", "1");
  }
  ~ScopedSoftwareEGL() {
    // Restore in reverse so a name touched twice ends on its original value.
    for (auto it = saved_.rbegin(); it != saved_.rend(); ++it) {
      if (it->had)
        setenv(it->name, it->prev.c_str(), 1);
      else
        unsetenv(it->name);
    }
  }
  ScopedSoftwareEGL(const ScopedSoftwareEGL&) = delete;
  ScopedSoftwareEGL& operator=(const ScopedSoftwareEGL&) = delete;

 private:
  struct Var {
    const char* name;
    bool had;
    std::string prev;
  };
  std::vector<Var> saved_;
  void snapshot(const char* name) {
    const char* v = std::getenv(name);
    saved_.push_back({name, v != nullptr, v ? v : std::string()});
  }
  void hide(const char* name) {
    snapshot(name);
    unsetenv(name);
  }
  void force(const char* name, const char* value) {
    snapshot(name);
    setenv(name, value, 1);
  }
};

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

// Open the off-screen display on the surfaceless Mesa platform (no window
// system, no device node needed), via the 1.5 core entry point then the EXT
// entry point. This is the path the headless gl_test uses successfully.
EGLDisplay open_surfaceless_display() {
#if defined(EGL_VERSION_1_5)
  EGLDisplay d = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA,
                                       EGL_DEFAULT_DISPLAY, nullptr);
  if (d != EGL_NO_DISPLAY)
    return d;
#endif
  auto get_platform_display = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
      eglGetProcAddress("eglGetPlatformDisplayEXT"));
  if (get_platform_display)
    return get_platform_display(EGL_PLATFORM_SURFACELESS_MESA,
                                EGL_DEFAULT_DISPLAY, nullptr);
  return EGL_NO_DISPLAY;
}

// Open the off-screen display on an explicit EGL device (via
// EGL_EXT_platform_device + EGL_EXT_device_enumeration), preferring a device
// that advertises software
// rendering (EGL_MESA_device_software, i.e. llvmpipe). Unlike the surfaceless
// and default platforms, a device display is tied to a concrete device rather
// than resolved through the window-system path — so it is immune to the EGL
// routing state that SDL's X11 connection sets up in the main binary, where the
// surfaceless make-current fails with EGL_BAD_ACCESS while the headless
// gl_test's identical code succeeds.
EGLDisplay open_device_display() {
  auto query_devices = reinterpret_cast<PFNEGLQUERYDEVICESEXTPROC>(
      eglGetProcAddress("eglQueryDevicesEXT"));
  auto query_device_string = reinterpret_cast<PFNEGLQUERYDEVICESTRINGEXTPROC>(
      eglGetProcAddress("eglQueryDeviceStringEXT"));
  auto get_platform_display = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
      eglGetProcAddress("eglGetPlatformDisplayEXT"));
  if (!query_devices || !get_platform_display)
    return EGL_NO_DISPLAY;

  EGLDeviceEXT devices[16];
  EGLint n = 0;
  if (!query_devices(16, devices, &n) || n <= 0)
    return EGL_NO_DISPLAY;

  EGLDeviceEXT chosen = EGL_NO_DEVICE_EXT;
  for (EGLint i = 0; i < n; ++i) {
    const char* ext = query_device_string
                          ? query_device_string(devices[i], EGL_EXTENSIONS)
                          : nullptr;
    if (ext && std::strstr(ext, "EGL_MESA_device_software")) {
      chosen = devices[i];
      break;
    }
  }
  if (chosen == EGL_NO_DEVICE_EXT)
    chosen = devices[0];
  return get_platform_display(EGL_PLATFORM_DEVICE_EXT, chosen, nullptr);
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

// Initialise `dpy` and bind a fresh ES context on it, preferring a surfaceless
// make-current with a 1x1-pbuffer fallback. `label` names the display strategy
// for the log. On success returns true with *out_egl / *out_surf filled and the
// context left current; on failure logs the reason, tears down anything it
// created, leaves nothing current, and returns false so the caller can try the
// next display strategy.
bool bind_context(EGLDisplay dpy,
                  const char* label,
                  EGLContext* out_egl,
                  EGLSurface* out_surf) {
  EGLint major = 0, minor = 0;
  if (!eglInitialize(dpy, &major, &minor)) {
    warn("bind_context: eglInitialize failed", label);
    return false;
  }
  {
    char buf[256];
    const char* vnd = eglQueryString(dpy, EGL_VENDOR);
    const char* ver = eglQueryString(dpy, EGL_VERSION);
    const char* ext = eglQueryString(dpy, EGL_EXTENSIONS);
    std::snprintf(buf, sizeof(buf), "%s: vendor=%s version=%s surfaceless=%s",
                  label, vnd ? vnd : "?", ver ? ver : "?",
                  (ext && std::strstr(ext, "EGL_KHR_surfaceless_context"))
                      ? "yes"
                      : "no");
    warn("bind_context: EGL initialized", buf);
  }
  if (!eglBindAPI(EGL_OPENGL_ES_API)) {
    warn("bind_context: eglBindAPI(EGL_OPENGL_ES_API) failed", label);
    return false;
  }

  EGLConfig cfg = nullptr;
  if (!choose_config(dpy, &cfg)) {
    warn("bind_context: eglChooseConfig found no RGBA8 config", label);
    return false;
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
    warn("bind_context: eglCreateContext failed", label);
    return false;
  }

  // Prefer surfaceless (EGL_KHR_surfaceless_context, which llvmpipe advertises)
  // — an FBO is the render target, so no draw/read surface is needed. A driver
  // that rejects a no-surface make-current falls back to a 1x1 pbuffer (the
  // config advertises EGL_PBUFFER_BIT); it exists only to satisfy make-current.
  EGLSurface surf = EGL_NO_SURFACE;
  if (!eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, egl)) {
    const EGLint surfaceless_err = eglGetError();
    const EGLint pb_attribs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    surf = eglCreatePbufferSurface(dpy, cfg, pb_attribs);
    if (surf == EGL_NO_SURFACE || !eglMakeCurrent(dpy, surf, surf, egl)) {
      char buf[256];
      std::snprintf(
          buf, sizeof(buf),
          "%s: surfaceless err=0x%04x; pbuffer makeCurrent err=0x%04x", label,
          surfaceless_err, eglGetError());
      warn("bind_context: eglMakeCurrent failed (surfaceless and pbuffer)",
           buf);
      if (surf != EGL_NO_SURFACE)
        eglDestroySurface(dpy, surf);
      eglDestroyContext(dpy, egl);
      return false;
    }
  }
  *out_egl = egl;
  *out_surf = surf;
  return true;
}

}  // namespace

struct Context {
  EGLDisplay dpy = EGL_NO_DISPLAY;
  EGLContext egl = EGL_NO_CONTEXT;
  // The surface bound by eglMakeCurrent. Normally EGL_NO_SURFACE (surfaceless),
  // but a 1x1 pbuffer where the driver rejects a no-surface make-current (see
  // create). Rendering always targets `fbo`, so the surface is unused for draw.
  EGLSurface surf = EGL_NO_SURFACE;
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

  // Settle whether a foreign EGL context is the culprit (it is not, in the
  // main binary: LVGL's SDL backend uses the software renderer and creates no
  // GL context) — a bind conflict would show up here.
  if (eglGetCurrentContext() != EGL_NO_CONTEXT)
    warn("create: an EGL context was already current on this thread", nullptr);

  ScopedSoftwareEGL no_x;

  // Try the surfaceless platform first (what the headless gl_test uses), then
  // an explicit software EGL device. In the main binary (SDL + Xvfb) the
  // surfaceless make-current fails with EGL_BAD_ACCESS — SDL's X11 connection
  // perturbs the window-system EGL path — so the device platform, tied to a
  // concrete device rather than resolved through the window system, is the
  // fallback that keeps MZ booting there.
  struct Candidate {
    EGLDisplay dpy;
    const char* label;
  };
  Candidate candidates[2];
  int n = 0;
  EGLDisplay sdpy = open_surfaceless_display();
  if (sdpy != EGL_NO_DISPLAY)
    candidates[n++] = {sdpy, "surfaceless"};
  EGLDisplay ddpy = open_device_display();
  if (ddpy != EGL_NO_DISPLAY)
    candidates[n++] = {ddpy, "device"};
  if (n == 0) {
    warn("create: no EGL display (surfaceless and device unavailable)",
         nullptr);
    return nullptr;
  }

  EGLDisplay dpy = EGL_NO_DISPLAY;
  EGLContext egl = EGL_NO_CONTEXT;
  EGLSurface surf = EGL_NO_SURFACE;
  for (int i = 0; i < n; ++i) {
    if (bind_context(candidates[i].dpy, candidates[i].label, &egl, &surf)) {
      dpy = candidates[i].dpy;
      break;
    }
  }
  if (dpy == EGL_NO_DISPLAY) {
    warn("create: no EGL display could bind a context", nullptr);
    return nullptr;
  }

  Context* ctx = new Context();
  ctx->dpy = dpy;
  ctx->egl = egl;
  ctx->surf = surf;
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
    ScopedSoftwareEGL no_x;
    eglMakeCurrent(ctx->dpy, ctx->surf, ctx->surf, ctx->egl);
    if (ctx->fbo)
      glDeleteFramebuffers(1, &ctx->fbo);
    if (ctx->color_rb)
      glDeleteRenderbuffers(1, &ctx->color_rb);
    if (ctx->ds_rb)
      glDeleteRenderbuffers(1, &ctx->ds_rb);
    eglMakeCurrent(ctx->dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (ctx->surf != EGL_NO_SURFACE)
      eglDestroySurface(ctx->dpy, ctx->surf);
    eglDestroyContext(ctx->dpy, ctx->egl);
    // The display is process-shared and refcounted by eglInitialize; leave it
    // initialised rather than tearing it down under any other live context.
  }
  delete ctx;
}

bool resize(Context* ctx, int width, int height) {
  if (!ctx || width <= 0 || height <= 0)
    return false;
  if (ctx->w == width && ctx->h == height)
    return true;
  if (!make_current(ctx))
    return false;

  // Reallocate both attachments at the new size. glRenderbufferStorage
  // re-specifies the existing renderbuffer, so the FBO's attachment points stay
  // valid and only the storage changes.
  glBindRenderbuffer(GL_RENDERBUFFER, ctx->color_rb);
  glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, width, height);
  glBindRenderbuffer(GL_RENDERBUFFER, ctx->ds_rb);
  glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, width, height);
  if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
    warn("resize: framebuffer incomplete", nullptr);
    return false;
  }

  ctx->w = width;
  ctx->h = height;
  const size_t bytes = static_cast<size_t>(width) * height * 4;
  ctx->buffer.assign(bytes, 0);
  ctx->flipped.assign(bytes, 0);
  glViewport(0, 0, width, height);
  return true;
}

bool make_current(Context* ctx) {
  if (!ctx || ctx->dpy == EGL_NO_DISPLAY || ctx->egl == EGL_NO_CONTEXT)
    return false;
  ScopedSoftwareEGL no_x;
  if (!eglMakeCurrent(ctx->dpy, ctx->surf, ctx->surf, ctx->egl))
    return false;
  // A fresh make-current binds the default framebuffer; rebind ours (the
  // pbuffer/none surface is not a render target) so draws and readback hit it.
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
      if (!ok) {
        char detail[64];
        std::snprintf(detail, sizeof(detail), "%d,%d,%d,%d", px[0], px[1],
                      px[2], px[3]);
        warn("smoke_test unexpected centre pixel", detail);
      }
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
bool resize(Context*, int, int) {
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
