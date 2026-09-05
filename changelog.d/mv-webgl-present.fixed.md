- MV: every game rendered as a blank screen, both on-screen and in every
  screenshot, since the WebGL backend landed. `Graphics._rendererType`
  defaults to `'auto'` (rpg_core.js), and `PIXI.autoDetectRenderer` picks
  `WebGLRenderer` whenever `canvas.getContext('webgl')` succeeds — which is
  unconditional for every maker now, not only MZ — so MV has silently
  rendered through WebGL into the native GLES2 backend's own framebuffer ever
  since, while `MV#present`/`#maybe_screenshot` kept reading back the plain
  Canvas2D buffer PIXI's `WebGLRenderer` never touches. Fixed by giving `MV`
  the same WebGL-handle branch `MZ` already has, so a real downloaded MV game
  (`data/Lunatic-Core`) now shows its actual title screen, map and battle
  art instead of a blank frame. CI's MV screenshot smoke tests needed a
  timeout bump alongside this, since a real WebGL framebuffer readback costs
  real time the previous blank copy never did.
