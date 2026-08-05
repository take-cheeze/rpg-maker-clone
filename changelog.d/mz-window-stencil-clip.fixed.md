- MZ: windows no longer overpaint each other. `WindowLayer.render` clips each
  window to its own shape with the stencil buffer — draw where the buffer is 0,
  stamp the shape with `REPLACE`, so a window behind cannot paint over the one in
  front — but the WebGL wrapper accepted `stencilFunc`/`stencilOp`/`stencilMask`
  and threw them away, so the clip was a no-op. All three now map onto GL, as
  does `clearStencil`. The off-screen FBO's packed DEPTH24_STENCIL8 buffer had
  been attached since the backend landed; it was simply never programmed.
  `gl_test` asserts the masking at the pixel level on the real backend: stamp the
  left half, draw a full-screen quad, and only the right half survives.
