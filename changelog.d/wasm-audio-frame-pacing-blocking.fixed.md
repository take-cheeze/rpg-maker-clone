- **Delayed/glitchy audio in the browser build.** `Graphics.update`'s 60fps
  frame-pacing wait used a real blocking sleep every frame; on desktop that
  costs only wall clock (SDL_mixer mixes on its own OS thread), but the
  Emscripten build has no such thread — its Web Audio callback runs on the
  same single JS thread as the game loop, which the blocking sleep froze on
  every frame. `emscripten_set_main_loop` now paces itself at 60fps via its
  own non-blocking scheduling instead of raw vsync (`src/main.cxx`), and the
  in-engine sleep is skipped under `__EMSCRIPTEN__` in favour of it
  (`mruby-rgss/src/lib.cxx`). `Mix_OpenAudio`'s buffer is also halved for the
  browser build (2048 → 1024 samples, `src/sdl_audio.cxx`), cutting baseline
  latency now that the thread is far less likely to be blocked for a long
  stretch. See `docs/profiling.md`.
