- **RPG Maker MZ**: an animation whose `effectName` names a real Effekseer
  effect no longer runs entirely silently. `window.effekseer` is now a
  diagnostic stub instead of the unusable-here WASM runtime — it makes
  `Graphics.effekseer` non-null so the engine's own load path actually runs,
  reads the real `.efkefc` bytes off disk to confirm the file exists and
  looks like a real effect container, and logs exactly what was skipped and
  why. Sound/flash timings on the animation still fire and it still
  completes normally; native particle rendering itself is not implemented
  (tracked separately — see `docs/adr/0004-rpg-maker-mv-support.md` M6.2).
