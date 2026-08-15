- **Profiler sections for the map renderer and the audio path**, so
  `--profile` reports where a map frame actually goes instead of showing one
  opaque `scene.update` bar. `Scene::Map` now times `map.render` and its
  phases (`map.layers`, `map.parallax`, `map.chars`, `map.animation`,
  `map.pictures`, `map.overlay`, `map.animate_events`, `map.refresh_pages`),
  and the SDL_mixer
  backend times `audio.music_load`, `audio.sample_load` and `audio.update`
  alongside the Ruby-side `audio.resolve` asset search. Measured on Nepheshel,
  this attributes 67% of frame work to `map.layers` — the per-tile blit loop
  that redraws both chip layers from scratch every frame — and confirms the
  steady-state audio cost on the game-loop thread is ~0ms, since SDL_mixer
  already decodes and mixes on its own thread. See `docs/profiling.md`.
