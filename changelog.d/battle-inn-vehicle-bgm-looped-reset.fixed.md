- **Entering battle, an inn, or boarding/leaving a vehicle now correctly
  resets the "has the current BGM looped once" flag for its own fresh
  track.** `Scene::Map#play_bgm` — the shared entry point for battle/inn/
  vehicle BGM — never reset `@state.bgm_looped` when starting a genuinely
  new track, unlike every other BGM-start path (`Game::Interpreter#play_audio`'s
  `:bgm` branch, `#do_play_memorized_bgm`, `#resume_saved_bgm`). A
  Conditional Branch checking "has the BGM looped" (type 9) right after one
  of these transitions could read a stale `true` left over from whichever
  track was playing before, even though the new one had not played a single
  frame yet.
