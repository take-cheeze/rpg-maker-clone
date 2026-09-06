- **Delayed/glitchy audio in the browser build, worst while holding a movement
  key.** `Graphics.update`'s 60fps frame-pacing wait used a real blocking
  sleep every frame; on desktop that costs only wall clock (SDL_mixer mixes
  on its own OS thread), but the Emscripten build has no such thread — its
  Web Audio callback runs on the same single JS thread as the game loop,
  which the blocking sleep froze on every frame. `emscripten_set_main_loop`
  now paces itself at 60fps via its own non-blocking scheduling instead of
  raw vsync (`src/main.cxx`), and the in-engine sleep is skipped under
  `__EMSCRIPTEN__` in favour of it (`mruby-rgss/src/lib.cxx`). Separately,
  `Mix_OpenAudio`'s buffer is now larger for the browser build (2048 → 4096
  samples, `src/sdl_audio.cxx`): a ScriptProcessorNode callback that fires
  late does not resync, it just stays behind by however late it was, and
  that lateness compounds on every further stall — sustained input (holding
  a direction key keeps the per-frame camera/animation/collision cost
  running every frame, occasionally alongside the tile-crossing cache
  rebuild) is exactly the case likeliest to trigger it, and the audible
  delay this produces is far worse than a bigger fixed buffer. See
  `docs/profiling.md`.
