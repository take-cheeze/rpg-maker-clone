// Native Effekseer integration (see mvefk.hxx for the milestone this lands).

#include "mvefk.hxx"

#include "mvhost.hxx"  // mv_install_effekseer's declaration; always available.

// Unlike mvgl.cxx (which decides purely from `__has_include`, since EGL/
// GLES2 headers/libs are found via the default system search path with no
// extra wiring needed), this gate hinges on a define mrbgem.rake sets
// (MVJS_EFFEKSEER_BUILD_ENABLED) rather than probing header availability
// itself. Effekseer.h lives in a vendored submodule that needs an explicit
// `-I`, so a bare `__has_include` probe here can disagree with whether
// mrbgem.rake actually wired that include path (and the matching link
// libraries) up for *this* compiler invocation -- concretely, the native
// "host" mruby sub-build a cross target (emscripten) builds internally to
// get mrbc: that compiler really does find real EGL/GLES3 headers on a
// dev machine, but mrbgem.rake's own have_egl/have_gles3 checks are keyed
// off ENV["MRUBY_TARGET"], which a cross build sets for its whole rake
// process (host sub-build included), so they never add the Effekseer `-I`/
// link wiring there. Depending on this define instead of re-probing
// capability keeps the two in agreement by construction: see mrbgem.rake's
// own comment beside where it's defined.
#if defined(MVJS_EFFEKSEER_BUILD_ENABLED) && !defined(__EMSCRIPTEN__)
#define MVJS_HAVE_EFFEKSEER 1

#include <GLES3/gl3.h>

#include <cstddef>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "Effekseer.h"
#include "EffekseerRendererGL.h"
#include "mvgl.hxx"
#include "terminal.hxx"  // log_bridge_write_stderr, shared with mvgl.cxx

namespace mvefk {

namespace {

void warn(const char* what, const char* detail) {
  const std::string msg = std::string("[MZ-EFK] ") + what +
                          (detail ? ": " : "") + (detail ? detail : "");
  log_bridge_write_stderr(msg.c_str());
}

}  // namespace

bool available() {
  return mvgl::available();
}

bool smoke_test(const char* path,
                int width,
                int height,
                int warmup_frames,
                std::uint32_t* out_lit_pixel_count) {
  if (!mvgl::available()) {
    warn("smoke_test: mvgl backend not available", nullptr);
    return false;
  }

  mvgl::Context* ctx = mvgl::create(width, height);
  if (!ctx) {
    warn("smoke_test: mvgl::create failed", nullptr);
    return false;
  }
  if (!mvgl::make_current(ctx)) {
    warn("smoke_test: mvgl::make_current failed", nullptr);
    mvgl::destroy(ctx);
    return false;
  }

  // The instance cap (2000) and sprite cap passed to Create below are the
  // same order of magnitude EffectPlatform.cpp's own default uses; this is a
  // one-effect smoke test, not a real game's worst case, so headroom matters
  // more than tuning it precisely.
  Effekseer::ManagerRef manager = Effekseer::Manager::Create(2000);
  if (!manager) {
    warn("smoke_test: Effekseer::Manager::Create failed", nullptr);
    mvgl::destroy(ctx);
    return false;
  }

  EffekseerRendererGL::RendererRef renderer =
      EffekseerRendererGL::Renderer::Create(
          2000, EffekseerRendererGL::OpenGLDeviceType::OpenGLES3);
  if (!renderer) {
    warn("smoke_test: EffekseerRendererGL::Renderer::Create failed", nullptr);
    mvgl::destroy(ctx);
    return false;
  }

  manager->SetSpriteRenderer(renderer->CreateSpriteRenderer());
  manager->SetRibbonRenderer(renderer->CreateRibbonRenderer());
  manager->SetRingRenderer(renderer->CreateRingRenderer());
  manager->SetModelRenderer(renderer->CreateModelRenderer());
  manager->SetTrackRenderer(renderer->CreateTrackRenderer());
  manager->SetTextureLoader(renderer->CreateTextureLoader());
  manager->SetModelLoader(renderer->CreateModelLoader());
  manager->SetMaterialLoader(renderer->CreateMaterialLoader());
  manager->SetCoordinateSystem(Effekseer::CoordinateSystem::RH);

  char16_t path16[1024] = {};
  Effekseer::ConvertUtf8ToUtf16(path16, 1024, path);
  Effekseer::EffectRef effect = Effekseer::Effect::Create(manager, path16);
  if (!effect) {
    warn("smoke_test: Effekseer::Effect::Create failed", path);
    mvgl::destroy(ctx);
    return false;
  }

  Effekseer::Handle handle = manager->Play(effect, 0.0f, 0.0f, 0.0f);
  for (int i = 0; i < warmup_frames; ++i)
    manager->Update(1.0f);
  // Manager::Update's autoFlip (on by default, used here) syncs the
  // render-visible DrawSet snapshot at the *start* of Update, from state as
  // of the previous Update call -- so without this, DrawHandle below would
  // draw the state as of warmup_frames-1, one full simulation step stale.
  // A real per-frame game loop never notices (each frame's draw is always
  // one step behind that frame's own Update, consistently), but a one-shot
  // simulate-then-draw call like this one needs an explicit extra Flip() to
  // see the just-completed frame's state.
  manager->Flip();

  glBindFramebuffer(GL_FRAMEBUFFER, mvgl::default_framebuffer(ctx));
  glViewport(0, 0, width, height);
  // A mid-grey clear, not black or white: real effect content (particle
  // textures, additive glows) is very unlikely to land exactly on either
  // extreme, so a mid-tone background gives the "did anything draw" pixel
  // comparison below the least chance of a false negative from an effect
  // that happens to draw pure black or pure white pixels.
  glClearColor(0.5f, 0.5f, 0.5f, 1.0f);
  glClearDepthf(1.0f);
  glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

  // A generic camera looking at the origin from a 45-degree-ish angle, the
  // same shape TestRuntimeFramework/Runtime/EffectPlatform.cpp's own RH setup
  // uses. This is not MZ's own camera/projection convention (that comes with
  // the JS-bridge milestone, matching Sprite_Animation._render's own
  // setProjectionMatrix/setCameraMatrix calls) -- it only needs to place a
  // freshly-played effect in view so this smoke test can tell "rendered
  // something" from "rendered nothing".
  const Effekseer::Vector3D cam_pos(10.0f, 5.0f, 10.0f);
  const Effekseer::Vector3D cam_focus(0.0f, 0.0f, 0.0f);
  const float znear = 1.0f;
  const float zfar = 1000.0f;
  renderer->SetCameraMatrix(Effekseer::Matrix44().LookAtRH(
      cam_pos, cam_focus, Effekseer::Vector3D(0.0f, 1.0f, 0.0f)));
  renderer->SetProjectionMatrix(Effekseer::Matrix44().PerspectiveFovRH_OpenGL(
      90.0f / 180.0f * 3.14159f,
      static_cast<float>(width) / static_cast<float>(height), znear, zfar));

  // Manager::DrawHandle's default DrawParameter() leaves ViewProjectionMatrix
  // at its default (effectively identity) and ZNear/ZFar both at 0.0f. Two
  // real integration pitfalls, found by tracing why a correctly-simulated
  // effect (confirmed via Manager::GetTotalInstanceCount()) produced zero
  // rendered pixels with no GL error anywhere:
  //
  //  1. ZNear/ZFar both 0.0f (equal) does at least skip the CPU-side sphere
  //     culling check in ManagerImplemented::CanDraw (Effekseer.Manager.cpp
  //     only runs it `if (ZNear != ZFar)`), so a mismatched or degenerate
  //     ViewProjectionMatrix is not actually the culprit by itself for an
  //     effect whose own Culling.Shape isn't Sphere -- but DrawParameter's
  //     other camera fields still need to be populated for a materially
  //     correct render, so they are set explicitly here regardless.
  //  2. GetCameraProjectionMatrix() must be read *after* BeginRendering(),
  //     not before: EffekseerRendererGL::RendererImplemented::BeginRendering
  //     (EffekseerRendererGL.Renderer.cpp) is the only place that calls
  //     impl->CalculateCameraProjectionMatrix() to combine the matrices
  //     SetCameraMatrix/SetProjectionMatrix just set; reading it earlier
  //     silently returns whatever was combined on a *previous* call (or an
  //     unset value on the very first one).
  renderer->BeginRendering();
  Effekseer::Manager::DrawParameter draw_param;
  draw_param.ViewProjectionMatrix = renderer->GetCameraProjectionMatrix();
  draw_param.ZNear = znear;
  draw_param.ZFar = zfar;
  draw_param.CameraPosition = cam_pos;
  draw_param.CameraFrontDirection =
      Effekseer::Vector3D::Normal(cam_focus - cam_pos);
  manager->DrawHandle(handle, draw_param);
  renderer->EndRendering();

  int out_w = 0, out_h = 0;
  const std::uint8_t* px = mvgl::pixels(ctx, &out_w, &out_h);
  if (!px) {
    warn("smoke_test: mvgl::pixels returned null", nullptr);
    mvgl::destroy(ctx);
    return false;
  }

  std::uint32_t lit = 0;
  const int tolerance = 8;  // out of 255, past which a pixel is "changed"
  for (int i = 0; i < out_w * out_h; ++i) {
    const std::uint8_t* p = px + i * 4;
    if (std::abs(static_cast<int>(p[0]) - 128) > tolerance ||
        std::abs(static_cast<int>(p[1]) - 128) > tolerance ||
        std::abs(static_cast<int>(p[2]) - 128) > tolerance) {
      ++lit;
    }
  }
  *out_lit_pixel_count = lit;

  manager->StopEffect(handle);
  mvgl::destroy(ctx);
  return true;
}

// -- persistent JS-bridge simulation context ---------------------------------

namespace {

// One entry per live ContextId (index + 1; 0 is the null id), mirroring
// mvwebgl.cxx's g_gl idiom. A context outlives individual effects/handles;
// MZ creates exactly one for the whole game (Graphics.effekseer) and never
// destroys it, but context_destroy exists for tests.
struct Context {
  Effekseer::ManagerRef manager;
  // Null until init_render succeeds -- see mvefk.hxx's own comment on why
  // this is a separate step from context_create, mirroring the real
  // effekseer.js createContext()/init(gl) split.
  EffekseerRendererGL::RendererRef renderer;
  // Effects loaded into this context, by EffectId (index + 1; 0 is null),
  // kept alive here since Effekseer::Handle alone does not hold a strong
  // reference the caller can query back.
  std::vector<Effekseer::EffectRef> effects;
};

std::vector<Context*> g_contexts;

Context* find_context(ContextId ctx) {
  if (ctx < 1 || static_cast<std::size_t>(ctx) > g_contexts.size())
    return nullptr;
  return g_contexts[static_cast<std::size_t>(ctx) - 1];
}

}  // namespace

ContextId context_create() {
  if (!available()) {
    warn("context_create: backend not available", nullptr);
    return 0;
  }
  auto* c = new Context();
  // Same instance cap as smoke_test's own Manager::Create -- headroom for a
  // real game's several-animations-at-once case, not tuned per-effect.
  c->manager = Effekseer::Manager::Create(2000);
  if (!c->manager) {
    warn("context_create: Effekseer::Manager::Create failed", nullptr);
    delete c;
    return 0;
  }
  c->manager->SetCoordinateSystem(Effekseer::CoordinateSystem::RH);
  g_contexts.push_back(c);
  return static_cast<ContextId>(g_contexts.size());
}

void context_destroy(ContextId ctx) {
  Context* c = find_context(ctx);
  if (!c)
    return;
  delete c;
  g_contexts[static_cast<std::size_t>(ctx) - 1] = nullptr;
}

EffectId effect_load(ContextId ctx,
                     const std::uint8_t* bytes,
                     std::size_t len,
                     float magnification,
                     const char* path) {
  Context* c = find_context(ctx);
  if (!c || !bytes || len == 0)
    return 0;

  // See mvefk.hxx's own comment on why this is needed at all: without it,
  // every texture/model/material the effect references fails to load and it
  // draws nothing. `mv_resolve_path` (mvhost.hxx/mvjs.cxx) is the same
  // game-dir-rooting every other MZ asset load already goes through, so this
  // materialPath is an absolute filesystem directory -- immune to whatever
  // this process' own CWD happens to be, unlike a bare relative path handed
  // straight to Effekseer's own DefaultFileInterface.
  char16_t material_path16[1024] = {};
  if (path && *path) {
    const std::string abs = mv_resolve_path(path);
    const std::size_t slash = abs.find_last_of('/');
    const std::string dir =
        slash == std::string::npos ? std::string() : abs.substr(0, slash + 1);
    Effekseer::ConvertUtf8ToUtf16(material_path16, 1024, dir.c_str());
  }

  Effekseer::EffectRef effect = Effekseer::Effect::Create(
      c->manager, bytes, static_cast<int32_t>(len), magnification,
      material_path16[0] ? material_path16 : nullptr);
  if (!effect)
    return 0;
  c->effects.push_back(effect);
  return static_cast<EffectId>(c->effects.size());
}

void effect_release(ContextId ctx, EffectId effect) {
  Context* c = find_context(ctx);
  if (!c || effect < 1 || static_cast<std::size_t>(effect) > c->effects.size())
    return;
  c->effects[static_cast<std::size_t>(effect) - 1] = nullptr;
}

std::int32_t play(ContextId ctx, EffectId effect, float x, float y, float z) {
  Context* c = find_context(ctx);
  if (!c || effect < 1 || static_cast<std::size_t>(effect) > c->effects.size())
    return -1;
  const Effekseer::EffectRef& e =
      c->effects[static_cast<std::size_t>(effect) - 1];
  if (!e)
    return -1;
  return c->manager->Play(e, x, y, z);
}

void set_location(ContextId ctx,
                  std::int32_t handle,
                  float x,
                  float y,
                  float z) {
  Context* c = find_context(ctx);
  if (!c || handle < 0)
    return;
  c->manager->SetLocation(handle, x, y, z);
}

void set_rotation(ContextId ctx,
                  std::int32_t handle,
                  float x,
                  float y,
                  float z) {
  Context* c = find_context(ctx);
  if (!c || handle < 0)
    return;
  c->manager->SetRotation(handle, x, y, z);
}

void set_scale(ContextId ctx, std::int32_t handle, float x, float y, float z) {
  Context* c = find_context(ctx);
  if (!c || handle < 0)
    return;
  c->manager->SetScale(handle, x, y, z);
}

void set_speed(ContextId ctx, std::int32_t handle, float speed) {
  Context* c = find_context(ctx);
  if (!c || handle < 0)
    return;
  c->manager->SetSpeed(handle, speed);
}

void stop(ContextId ctx, std::int32_t handle) {
  Context* c = find_context(ctx);
  if (!c || handle < 0)
    return;
  c->manager->StopEffect(handle);
}

bool handle_exists(ContextId ctx, std::int32_t handle) {
  Context* c = find_context(ctx);
  if (!c || handle < 0)
    return false;
  return c->manager->Exists(handle);
}

void update(ContextId ctx, float delta_frame) {
  Context* c = find_context(ctx);
  if (!c)
    return;
  c->manager->Update(delta_frame);
}

void stop_all(ContextId ctx) {
  Context* c = find_context(ctx);
  if (!c)
    return;
  c->manager->StopAllEffects();
}

bool init_render(ContextId ctx) {
  Context* c = find_context(ctx);
  if (!c)
    return false;
  if (c->renderer)
    return true;  // already attached -- see mvefk.hxx's own comment.

  // Same instance/sprite cap as smoke_test's own Renderer::Create -- headroom
  // for a real game's several-animations-at-once case, not tuned per-effect.
  c->renderer = EffekseerRendererGL::Renderer::Create(
      2000, EffekseerRendererGL::OpenGLDeviceType::OpenGLES3);
  if (!c->renderer) {
    warn("init_render: EffekseerRendererGL::Renderer::Create failed", nullptr);
    return false;
  }
  c->manager->SetSpriteRenderer(c->renderer->CreateSpriteRenderer());
  c->manager->SetRibbonRenderer(c->renderer->CreateRibbonRenderer());
  c->manager->SetRingRenderer(c->renderer->CreateRingRenderer());
  c->manager->SetModelRenderer(c->renderer->CreateModelRenderer());
  c->manager->SetTrackRenderer(c->renderer->CreateTrackRenderer());
  c->manager->SetTextureLoader(c->renderer->CreateTextureLoader());
  c->manager->SetModelLoader(c->renderer->CreateModelLoader());
  c->manager->SetMaterialLoader(c->renderer->CreateMaterialLoader());
  return true;
}

void set_projection_matrix(ContextId ctx, const float m[16]) {
  Context* c = find_context(ctx);
  if (!c || !c->renderer)
    return;
  Effekseer::Matrix44 mat;
  std::memcpy(mat.Values, m, sizeof(mat.Values));
  c->renderer->SetProjectionMatrix(mat);
}

void set_camera_matrix(ContextId ctx, const float m[16]) {
  Context* c = find_context(ctx);
  if (!c || !c->renderer)
    return;
  Effekseer::Matrix44 mat;
  std::memcpy(mat.Values, m, sizeof(mat.Values));
  c->renderer->SetCameraMatrix(mat);
}

void begin_draw(ContextId ctx) {
  Context* c = find_context(ctx);
  if (!c || !c->renderer)
    return;
  c->renderer->BeginRendering();
}

void draw_handle(ContextId ctx, std::int32_t handle) {
  Context* c = find_context(ctx);
  if (!c || !c->renderer || handle < 0)
    return;
  // GetCameraProjectionMatrix must be read after BeginRendering, not before
  // -- see smoke_test's own comment on this exact pitfall (it silently
  // returns a stale/unset value with no error from either library). No
  // explicit Flip() here (unlike smoke_test's one-shot simulate-then-draw):
  // this is called every real frame, and Manager::Create's autoFlip default
  // (true, used by context_create) already syncs the render-visible DrawSet
  // at the *start* of each `update()` call -- adding a second flip here would
  // desync that from the one-frame-behind cadence every other engine
  // (including the real effekseer.js/WASM build, whose DrawHandle has no
  // such call either) relies on.
  Effekseer::Manager::DrawParameter draw_param;
  draw_param.ViewProjectionMatrix = c->renderer->GetCameraProjectionMatrix();
  c->manager->DrawHandle(handle, draw_param);
}

void end_draw(ContextId ctx) {
  Context* c = find_context(ctx);
  if (!c || !c->renderer)
    return;
  // The actual GL draw calls DrawHandle queued (via each node's
  // AddVertexData) are not flushed until here: EffekseerRendererGL's
  // StandardRenderer only issues glDraw*/increments GetDrawCallCount() from
  // ResetAndRenderingIfRequired(), which BeginRendering()/EndRendering() call
  // -- not DrawHandle() itself. Confirmed directly while proving this
  // (temporary instrumentation on GetDrawCallCount() at each of these three
  // calls showed 0 after DrawHandle, 3 only once EndRendering ran) -- so
  // calling begin_draw/draw_handle without a matching end_draw leaves
  // whatever was drawn this frame stuck in the vertex buffer, unflushed.
  c->renderer->EndRendering();
}

}  // namespace mvefk

// -- JS bridge (__mv_efk* natives) -------------------------------------------
//
// Installed unconditionally (both branches of this file define
// mv_install_effekseer): MZ::EFFEKSEER_SHIM_JS calls these natives
// regardless of whether the real backend is compiled in, exactly like it
// already unconditionally calls __mv_existsSync/__mv_readFileBytes. Where
// mvefk's real functions are unavailable, every one of them already
// no-ops/returns its failure sentinel (see mvefk.hxx), so this stays a
// single code path either way -- only the JS side branches (on whether
// context_create returned a nonzero id), matching how it already branches
// on the honest-diagnostic magic-byte check.

namespace {

int32_t gi(JSContext* ctx, int argc, JSValueConst* argv, int i) {
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

// Mirrors mvwebgl.cxx's view_bytes: accepts a TypedArray view or a bare
// ArrayBuffer (EFFEKSEER_SHIM_JS always passes a Uint8Array, but this stays
// consistent with the rest of the host's bridges). `*hold` must be freed by
// the caller once done with the returned pointer.
uint8_t* efk_view_bytes(JSContext* ctx,
                        JSValueConst v,
                        size_t* out_len,
                        JSValue* hold) {
  size_t off = 0, len = 0, bpe = 0;
  JSValue ab = JS_GetTypedArrayBuffer(ctx, v, &off, &len, &bpe);
  if (JS_IsException(ab)) {
    JS_FreeValue(ctx, ab);
    JS_FreeValue(ctx, JS_GetException(ctx));
    size_t raw = 0;
    uint8_t* p = JS_GetArrayBuffer(ctx, &raw, v);
    if (!p) {
      JS_FreeValue(ctx, JS_GetException(ctx));
      *hold = JS_UNDEFINED;
      *out_len = 0;
      return nullptr;
    }
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

JSValue js_efk_context_create(JSContext* ctx,
                              JSValueConst,
                              int,
                              JSValueConst*) {
  return JS_NewUint32(ctx, mvefk::context_create());
}

JSValue js_efk_context_destroy(JSContext* ctx,
                               JSValueConst,
                               int argc,
                               JSValueConst* argv) {
  mvefk::context_destroy(static_cast<mvefk::ContextId>(gi(ctx, argc, argv, 0)));
  return JS_UNDEFINED;
}

JSValue js_efk_effect_load(JSContext* ctx,
                           JSValueConst,
                           int argc,
                           JSValueConst* argv) {
  const mvefk::ContextId cid =
      static_cast<mvefk::ContextId>(gi(ctx, argc, argv, 0));
  size_t len = 0;
  JSValue hold = JS_UNDEFINED;
  uint8_t* bytes =
      argc > 1 ? efk_view_bytes(ctx, argv[1], &len, &hold) : nullptr;
  const float mag =
      argc > 2 ? static_cast<float>(gd(ctx, argc, argv, 2)) : 1.0f;
  // The same `url` EFFEKSEER_SHIM_JS's loadEffect(url, ...) was given --
  // needed so effect_load can derive Effekseer's materialPath (see
  // mvefk.hxx's own comment on why). std::string, not a bare `const char*`
  // into JS-owned memory: JS_FreeCString below invalidates that pointer.
  std::string path;
  if (argc > 3) {
    const char* p = JS_ToCString(ctx, argv[3]);
    if (p) {
      path = p;
      JS_FreeCString(ctx, p);
    }
  }
  const mvefk::EffectId eid =
      mvefk::effect_load(cid, bytes, len, mag, path.empty() ? nullptr : path.c_str());
  JS_FreeValue(ctx, hold);
  return JS_NewUint32(ctx, eid);
}

JSValue js_efk_effect_release(JSContext* ctx,
                              JSValueConst,
                              int argc,
                              JSValueConst* argv) {
  mvefk::effect_release(static_cast<mvefk::ContextId>(gi(ctx, argc, argv, 0)),
                        static_cast<mvefk::EffectId>(gi(ctx, argc, argv, 1)));
  return JS_UNDEFINED;
}

JSValue js_efk_play(JSContext* ctx,
                    JSValueConst,
                    int argc,
                    JSValueConst* argv) {
  const int32_t h =
      mvefk::play(static_cast<mvefk::ContextId>(gi(ctx, argc, argv, 0)),
                  static_cast<mvefk::EffectId>(gi(ctx, argc, argv, 1)),
                  static_cast<float>(gd(ctx, argc, argv, 2)),
                  static_cast<float>(gd(ctx, argc, argv, 3)),
                  static_cast<float>(gd(ctx, argc, argv, 4)));
  return JS_NewInt32(ctx, h);
}

JSValue js_efk_set_location(JSContext* ctx,
                            JSValueConst,
                            int argc,
                            JSValueConst* argv) {
  mvefk::set_location(static_cast<mvefk::ContextId>(gi(ctx, argc, argv, 0)),
                      gi(ctx, argc, argv, 1),
                      static_cast<float>(gd(ctx, argc, argv, 2)),
                      static_cast<float>(gd(ctx, argc, argv, 3)),
                      static_cast<float>(gd(ctx, argc, argv, 4)));
  return JS_UNDEFINED;
}

JSValue js_efk_set_rotation(JSContext* ctx,
                            JSValueConst,
                            int argc,
                            JSValueConst* argv) {
  mvefk::set_rotation(static_cast<mvefk::ContextId>(gi(ctx, argc, argv, 0)),
                      gi(ctx, argc, argv, 1),
                      static_cast<float>(gd(ctx, argc, argv, 2)),
                      static_cast<float>(gd(ctx, argc, argv, 3)),
                      static_cast<float>(gd(ctx, argc, argv, 4)));
  return JS_UNDEFINED;
}

JSValue js_efk_set_scale(JSContext* ctx,
                         JSValueConst,
                         int argc,
                         JSValueConst* argv) {
  mvefk::set_scale(static_cast<mvefk::ContextId>(gi(ctx, argc, argv, 0)),
                   gi(ctx, argc, argv, 1),
                   static_cast<float>(gd(ctx, argc, argv, 2)),
                   static_cast<float>(gd(ctx, argc, argv, 3)),
                   static_cast<float>(gd(ctx, argc, argv, 4)));
  return JS_UNDEFINED;
}

JSValue js_efk_set_speed(JSContext* ctx,
                         JSValueConst,
                         int argc,
                         JSValueConst* argv) {
  mvefk::set_speed(static_cast<mvefk::ContextId>(gi(ctx, argc, argv, 0)),
                   gi(ctx, argc, argv, 1),
                   static_cast<float>(gd(ctx, argc, argv, 2)));
  return JS_UNDEFINED;
}

JSValue js_efk_stop(JSContext* ctx,
                    JSValueConst,
                    int argc,
                    JSValueConst* argv) {
  mvefk::stop(static_cast<mvefk::ContextId>(gi(ctx, argc, argv, 0)),
              gi(ctx, argc, argv, 1));
  return JS_UNDEFINED;
}

JSValue js_efk_exists(JSContext* ctx,
                      JSValueConst,
                      int argc,
                      JSValueConst* argv) {
  return JS_NewBool(ctx, mvefk::handle_exists(static_cast<mvefk::ContextId>(
                                                  gi(ctx, argc, argv, 0)),
                                              gi(ctx, argc, argv, 1)));
}

JSValue js_efk_update(JSContext* ctx,
                      JSValueConst,
                      int argc,
                      JSValueConst* argv) {
  mvefk::update(static_cast<mvefk::ContextId>(gi(ctx, argc, argv, 0)),
                static_cast<float>(gd(ctx, argc, argv, 1)));
  return JS_UNDEFINED;
}

JSValue js_efk_stop_all(JSContext* ctx,
                        JSValueConst,
                        int argc,
                        JSValueConst* argv) {
  mvefk::stop_all(static_cast<mvefk::ContextId>(gi(ctx, argc, argv, 0)));
  return JS_UNDEFINED;
}

// __mv_efkInit(ctx, glHandle) -> bool. `glHandle` is a WebGLRenderingContext's
// `.__gl` id (EFFEKSEER_SHIM_JS's ctx.init(gl) passes `gl.__gl`) -- resolve it
// to a real native GL context and make it current *before* attaching
// Effekseer's renderer, so `EffekseerRendererGL::Renderer::Create` (which
// queries the current context) attaches to the exact context/FBO PIXI's own
// WebGL renderer draws into, not merely whatever happened to be current.
// `glHandle <= 0` (real MZ never does this; a hand-written test fixture
// might) skips the make-current and lets init_render fail its own way if
// nothing is current.
JSValue js_efk_init(JSContext* ctx,
                    JSValueConst,
                    int argc,
                    JSValueConst* argv) {
  const mvefk::ContextId cid =
      static_cast<mvefk::ContextId>(gi(ctx, argc, argv, 0));
  const int32_t gl_handle = gi(ctx, argc, argv, 1);
  if (gl_handle > 0)
    mv_webgl_make_current(gl_handle);
  return JS_NewBool(ctx, mvefk::init_render(cid));
}

// A JS numeric array/TypedArray of (at least) 16 elements -> a flat float[16],
// for setProjectionMatrix/setCameraMatrix's mat4 argument. Deliberately
// separate from mvwebgl.cxx's own `num_array` (a different translation unit,
// and that one returns doubles for a variable-length uniform upload; this one
// always wants exactly 16 floats).
void read_mat4(JSContext* ctx, JSValueConst v, float out[16]) {
  for (uint32_t i = 0; i < 16; ++i) {
    JSValue e = JS_GetPropertyUint32(ctx, v, i);
    double d = 0;
    JS_ToFloat64(ctx, &d, e);
    JS_FreeValue(ctx, e);
    out[i] = static_cast<float>(d);
  }
}

JSValue js_efk_set_projection_matrix(JSContext* ctx,
                                     JSValueConst,
                                     int argc,
                                     JSValueConst* argv) {
  float m[16] = {};
  if (argc > 1)
    read_mat4(ctx, argv[1], m);
  mvefk::set_projection_matrix(
      static_cast<mvefk::ContextId>(gi(ctx, argc, argv, 0)), m);
  return JS_UNDEFINED;
}

JSValue js_efk_set_camera_matrix(JSContext* ctx,
                                 JSValueConst,
                                 int argc,
                                 JSValueConst* argv) {
  float m[16] = {};
  if (argc > 1)
    read_mat4(ctx, argv[1], m);
  mvefk::set_camera_matrix(
      static_cast<mvefk::ContextId>(gi(ctx, argc, argv, 0)), m);
  return JS_UNDEFINED;
}

JSValue js_efk_begin_draw(JSContext* ctx,
                         JSValueConst,
                         int argc,
                         JSValueConst* argv) {
  mvefk::begin_draw(static_cast<mvefk::ContextId>(gi(ctx, argc, argv, 0)));
  return JS_UNDEFINED;
}

JSValue js_efk_draw_handle(JSContext* ctx,
                          JSValueConst,
                          int argc,
                          JSValueConst* argv) {
  mvefk::draw_handle(static_cast<mvefk::ContextId>(gi(ctx, argc, argv, 0)),
                     gi(ctx, argc, argv, 1));
  return JS_UNDEFINED;
}

JSValue js_efk_end_draw(JSContext* ctx,
                       JSValueConst,
                       int argc,
                       JSValueConst* argv) {
  mvefk::end_draw(static_cast<mvefk::ContextId>(gi(ctx, argc, argv, 0)));
  return JS_UNDEFINED;
}

void reg(JSContext* ctx,
         JSValue g,
         const char* name,
         JSCFunction* fn,
         int argc) {
  JS_SetPropertyStr(ctx, g, name, JS_NewCFunction(ctx, fn, name, argc));
}

}  // namespace

void mv_install_effekseer(JSContext* ctx) {
  JSValue g = JS_GetGlobalObject(ctx);
  reg(ctx, g, "__mv_efkContextCreate", js_efk_context_create, 0);
  reg(ctx, g, "__mv_efkContextDestroy", js_efk_context_destroy, 1);
  reg(ctx, g, "__mv_efkEffectLoad", js_efk_effect_load, 4);
  reg(ctx, g, "__mv_efkEffectRelease", js_efk_effect_release, 2);
  reg(ctx, g, "__mv_efkPlay", js_efk_play, 5);
  reg(ctx, g, "__mv_efkSetLocation", js_efk_set_location, 5);
  reg(ctx, g, "__mv_efkSetRotation", js_efk_set_rotation, 5);
  reg(ctx, g, "__mv_efkSetScale", js_efk_set_scale, 5);
  reg(ctx, g, "__mv_efkSetSpeed", js_efk_set_speed, 3);
  reg(ctx, g, "__mv_efkStop", js_efk_stop, 2);
  reg(ctx, g, "__mv_efkExists", js_efk_exists, 2);
  reg(ctx, g, "__mv_efkUpdate", js_efk_update, 2);
  reg(ctx, g, "__mv_efkStopAll", js_efk_stop_all, 1);
  reg(ctx, g, "__mv_efkInit", js_efk_init, 2);
  reg(ctx, g, "__mv_efkSetProjectionMatrix", js_efk_set_projection_matrix, 2);
  reg(ctx, g, "__mv_efkSetCameraMatrix", js_efk_set_camera_matrix, 2);
  reg(ctx, g, "__mv_efkBeginDraw", js_efk_begin_draw, 1);
  reg(ctx, g, "__mv_efkDrawHandle", js_efk_draw_handle, 2);
  reg(ctx, g, "__mv_efkEndDraw", js_efk_end_draw, 1);
  JS_FreeValue(ctx, g);
}

#else  // !MVJS_HAVE_EFFEKSEER

namespace mvefk {

bool available() {
  return false;
}

bool smoke_test(const char* /*path*/,
                int /*width*/,
                int /*height*/,
                int /*warmup_frames*/,
                std::uint32_t* /*out_lit_pixel_count*/) {
  return false;
}

ContextId context_create() {
  return 0;
}

void context_destroy(ContextId /*ctx*/) {}

EffectId effect_load(ContextId /*ctx*/,
                     const std::uint8_t* /*bytes*/,
                     std::size_t /*len*/,
                     float /*magnification*/,
                     const char* /*path*/) {
  return 0;
}

void effect_release(ContextId /*ctx*/, EffectId /*effect*/) {}

std::int32_t play(ContextId /*ctx*/,
                  EffectId /*effect*/,
                  float /*x*/,
                  float /*y*/,
                  float /*z*/) {
  return -1;
}

void set_location(ContextId /*ctx*/,
                  std::int32_t /*handle*/,
                  float /*x*/,
                  float /*y*/,
                  float /*z*/) {}
void set_rotation(ContextId /*ctx*/,
                  std::int32_t /*handle*/,
                  float /*x*/,
                  float /*y*/,
                  float /*z*/) {}
void set_scale(ContextId /*ctx*/,
               std::int32_t /*handle*/,
               float /*x*/,
               float /*y*/,
               float /*z*/) {}
void set_speed(ContextId /*ctx*/, std::int32_t /*handle*/, float /*speed*/) {}
void stop(ContextId /*ctx*/, std::int32_t /*handle*/) {}

bool handle_exists(ContextId /*ctx*/, std::int32_t /*handle*/) {
  return false;
}

void update(ContextId /*ctx*/, float /*delta_frame*/) {}
void stop_all(ContextId /*ctx*/) {}

bool init_render(ContextId /*ctx*/) {
  return false;
}
void set_projection_matrix(ContextId /*ctx*/, const float /*m*/[16]) {}
void set_camera_matrix(ContextId /*ctx*/, const float /*m*/[16]) {}
void begin_draw(ContextId /*ctx*/) {}
void draw_handle(ContextId /*ctx*/, std::int32_t /*handle*/) {}
void end_draw(ContextId /*ctx*/) {}

}  // namespace mvefk

// No natives registered: EFFEKSEER_SHIM_JS feature-detects their absence
// (typeof g.__mv_efkContextCreate !== 'function') and stays on its
// synthetic, diagnostic-only path, exactly as it did before this bridge
// existed.
void mv_install_effekseer(JSContext*) {}

#endif  // MVJS_HAVE_EFFEKSEER
