// OSMesa-backed off-screen GLES2 context for the WebGL path (milestone M6.3a).
// See mvgl.hxx for why this exists and how it fits the software renderer.

#include "mvgl.hxx"

// The backend needs OSMesa + GLES2 headers. The Emscripten build renders MZ
// through the browser's own WebGL, and some environments (e.g. the nix build
// until OSMesa is packaged there) ship neither header — in both cases mvgl
// compiles to inert stubs and `available()` reports false. `__has_include`
// makes this a compile-time decision with no build-system probing.
#if !defined(__EMSCRIPTEN__) && __has_include(<GL/osmesa.h>) && \
    __has_include(<GLES2/gl2.h>)
#define MVJS_HAVE_OSMESA 1

#include <GL/osmesa.h>
#include <GLES2/gl2.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

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

}  // namespace

struct Context {
  OSMesaContext osmesa = nullptr;
  int w = 0;
  int h = 0;
  std::vector<std::uint8_t> buffer;   // RGBA8, bottom-up (GL order)
  std::vector<std::uint8_t> flipped;  // RGBA8, top-down (present order)
};

Context* create(int width, int height) {
  if (width <= 0 || height <= 0) {
    warn("create: non-positive dimensions", nullptr);
    return nullptr;
  }
  // Request a GLES2-capable context. OSMesa exposes only compat/core profiles,
  // but a compat context reached through libGLESv2 runs the ES entry points and
  // compiles ES 1.00 shaders, which is all PIXI needs (verified end to end by
  // smoke_test). Ask for >= 3.0 so the compat superset is comfortably ahead of
  // ES 2.0; Mesa returns at least what we ask for.
  const int attribs[] = {OSMESA_FORMAT,
                         OSMESA_RGBA,
                         OSMESA_DEPTH_BITS,
                         24,
                         OSMESA_STENCIL_BITS,
                         8,
                         OSMESA_PROFILE,
                         OSMESA_COMPAT_PROFILE,
                         OSMESA_CONTEXT_MAJOR_VERSION,
                         3,
                         OSMESA_CONTEXT_MINOR_VERSION,
                         0,
                         0};
  OSMesaContext osmesa = OSMesaCreateContextAttribs(attribs, nullptr);
  if (!osmesa) {
    warn("create: OSMesaCreateContextAttribs returned null", nullptr);
    return nullptr;
  }

  Context* ctx = new Context();
  ctx->osmesa = osmesa;
  ctx->w = width;
  ctx->h = height;
  ctx->buffer.assign(static_cast<size_t>(width) * height * 4, 0);
  if (!OSMesaMakeCurrent(osmesa, ctx->buffer.data(), GL_UNSIGNED_BYTE, width,
                         height)) {
    warn("create: OSMesaMakeCurrent failed", nullptr);
    OSMesaDestroyContext(osmesa);
    delete ctx;
    return nullptr;
  }
  // OSMesa's origin is bottom-left; ask it to present top-down so `pixels`
  // (and PIXI's own y-flip conventions) line up with the RGSS::Bitmap surface.
  OSMesaPixelStore(OSMESA_Y_UP, 0);
  return ctx;
}

void destroy(Context* ctx) {
  if (!ctx)
    return;
  if (ctx->osmesa)
    OSMesaDestroyContext(ctx->osmesa);
  delete ctx;
}

bool make_current(Context* ctx) {
  if (!ctx || !ctx->osmesa)
    return false;
  return OSMesaMakeCurrent(ctx->osmesa, ctx->buffer.data(), GL_UNSIGNED_BYTE,
                           ctx->w, ctx->h) == GL_TRUE;
}

const std::uint8_t* pixels(Context* ctx, int* out_w, int* out_h) {
  if (!ctx)
    return nullptr;
  if (out_w)
    *out_w = ctx->w;
  if (out_h)
    *out_h = ctx->h;
  // With OSMESA_Y_UP=0 the bound buffer is already top-down, so no extra flip
  // is needed; expose it directly.
  return ctx->buffer.data();
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

#else  // no OSMesa/GLES2 (Emscripten, or a build without the headers)

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
bool smoke_test(std::uint8_t[4]) {
  return false;
}
bool available() {
  return false;
}
}  // namespace mvgl

#endif
