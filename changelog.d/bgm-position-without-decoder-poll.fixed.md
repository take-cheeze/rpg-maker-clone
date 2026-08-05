- RPG Maker 2000 games with MIDI music no longer crawl. The runtime polls the
  BGM's playback position every frame to answer the *"BGM played once"*
  conditional branch, and `Mix_GetMusicPosition` is not a cheap getter: measured
  against SDL_mixer's MIDI decoder it took **1–3 seconds** to return — and then
  returned "unsupported" anyway, so the poll bought nothing. Nepheshel's opening
  ran at **0.5–5 frames a second**; it now holds 15–23. The position is tracked
  from the clock instead (the track's start time and its duration, asked for
  once per track), which is all the loop detection needs, and a stream whose
  length the decoder cannot report reads as position 0 throughout — the same
  answer a backend with no position support already gave.
