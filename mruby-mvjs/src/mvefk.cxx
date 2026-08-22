// Native Effekseer integration (see mvefk.hxx for the milestone this lands).

#include "mvefk.hxx"

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

#include <cstdio>
#include <cstring>
#include <string>

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

}  // namespace mvefk

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

}  // namespace mvefk

#endif  // MVJS_HAVE_EFFEKSEER
