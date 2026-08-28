- **Play BGM's fade-in parameter now actually fades the music in, instead of
  jumping straight to its target volume.** `Game::Interpreter#play_audio`'s
  `:bgm` branch read `fade_in` (the command's own param 0) off the event
  command but never forwarded it anywhere -- a track configured to fade in
  over, say, 800ms started at full volume immediately, indistinguishable
  from `fade_in=0`. `RGSS::Audio.bgm_play` gained a new 5th `fadein` argument
  (native backend: `src/sdl_audio.cxx` calls SDL_mixer's `Mix_FadeInMusic`
  instead of `Mix_PlayMusic` when it is non-zero), threaded through from Play
  BGM's own parameter and from Play Memorized BGM's memorized record (a
  track memorized mid-fade-in now resumes with that same ramp on replay,
  matching every other field -- volume/tempo/balance -- Memorize BGM already
  carries whole). The no-restart "same file already playing" shortcut is
  unaffected: there is no fresh play for a fade to ramp into there, matching
  every other Play BGM parameter's own same-file handling. Native playback
  timing is not independently confirmed against genuine RPG_RT's own audible
  ramp under wine (no screenshot-diff technique reaches audio); the
  parameter's presence, unit (milliseconds, matching liblcf's own BGM-struct
  field 2 Change System BGM and Fade Out BGM already use) and plumbing
  through every layer are confirmed by reading the LCF schema and this
  engine's own code.
- **Every stored BGM record's fade-in now survives Save/Continue instead of
  being silently dropped.** `Game::State#bgm_chunk`/`.bgm_from_chunk` (the
  shared encode/decode pair behind the current/memorized BGM, the pre-
  battle/vehicle restore points, and every Change System BGM override slot
  0-6) never touched LCF's BGM-struct field 2 (fade-in) at all -- a
  `fadein:` value set via Play BGM or Change System BGM was tracked live but
  silently lost the moment a save round-tripped it, the same class of gap
  balance (field 5) had before it was added. Fixed on the same "write only
  away from its own default" idiom the other fields already use.
