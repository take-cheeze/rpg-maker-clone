- **MZ's windows clip each other again.** The WebGL wrapper's renderbuffer calls
  (`createRenderbuffer` / `bindRenderbuffer` / `renderbufferStorage` /
  `framebufferRenderbuffer` / `deleteRenderbuffer`) were stubs, on the assumption
  that only the main FBO — which `mvgl.cxx` builds with its own packed
  DEPTH24_STENCIL8 buffer — ever needs a depth/stencil attachment. MZ never
  draws a scene there: every `Scene_Base` carries a `ColorFilter`, so the scene
  renders into a **filter render texture** and only the filter's output quad
  touches the main FBO. rmmz's `WindowLayer.render` asks PIXI for a stencil on
  whatever framebuffer is current (`renderer.framebuffer.forceStencil()`) and
  masks each window against the ones in front of it; with no attachment the
  stencil test always passed, so overlapping windows overpainted their
  neighbours. The five calls now map onto GL, translating the two WebGL1-only
  enums GLES2 lacks — the combined `DEPTH_STENCIL` internal format becomes
  `DEPTH24_STENCIL8`, and `DEPTH_STENCIL_ATTACHMENT` becomes an attach to both
  the depth and the stencil point. Covered at the pixel level by a new
  `mruby-mvjs/test/gl_test.rb` case that masks *inside* a framebuffer-attached
  render texture, which the stubs failed.
