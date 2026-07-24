# 5. Audio playback with SDL_mixer

Date: 2026-07-24

## Status

Accepted

## Context

`RGSS::Audio` was an inert stub: `bgm_play`, `se_play` and the rest warned once
and did nothing, so games ran silently and the event interpreter's Play BGM /
Play SE commands had no effect. We need real playback for the four RPG Maker
audio channels — BGM (looping music), BGS (looping ambience), ME (a one-shot
"music effect" that interrupts and then restores the BGM) and SE (overlapping
one-shot sound effects) — across the formats RPG2000/XP games ship (WAV, OGG,
MP3 and MIDI).

The project already links SDL2 for its window/input backend, and the codebase
has an established rule that the `mruby-rgss` gem must stay free of SDL: the gem
is also compiled for the standalone `rake test` binary and the Emscripten
variant, neither of which links an audio library, and the SDL keyboard bridge
already keeps all SDL specifics in the executable (`src/sdl_input.cxx`), talking
to the gem through plain `extern "C"` functions.

Options considered for the audio device:

- **SDL_mixer** — a thin, mature companion to SDL2 we already depend on. Handles
  device setup, mixing, format decoding, channel management and fades for us.
- **Raw SDL2 audio callbacks + our own mixer/decoders** — full control, but we
  would have to write mixing, resampling and format decoding (including linking
  the bundled `3rd/timidity` for MIDI) ourselves.
- **A higher-level engine (OpenAL, miniaudio, FMOD)** — more capability than a
  2D RPG needs, and a new heavyweight dependency.

## Decision

Use **SDL_mixer** as the audio backend, wired in with the same bridge pattern as
keyboard input so the gem stays SDL-free:

- `include/rgss_audio.hxx` declares an `RgssAudioBackend` function table (plain C
  types only, no mruby/SDL) plus `rgss_audio_install_backend()`.
- `mruby-rgss/src/audio.cxx` (gem side, no SDL) defines the native
  `RGSS::Audio._bgm_play` / `_se_play` / … primitives, which forward to the
  installed backend or no-op when none is installed.
- `src/sdl_audio.cxx` (executable side) implements the backend with SDL_mixer and
  installs it from `rgss_audio_init()`, called once at startup in `main()`.
- `mruby-rgss/mrblib/lib.rb` keeps the public `RGSS::Audio` API, resolving a
  game-supplied name to a real file (searching `GAME_DIR`/`RTP_DIR` crossed with
  the `Music`/`Sound`/`Audio/*` sub-folders and the known extensions, mirroring
  how `Bitmap` loads image assets) before calling the native primitive.

Channel mapping onto SDL_mixer: BGM and ME share the single `Mix_Music` stream
(ME plays once, then a per-frame check driven from `Graphics.update` reloads and
resumes the BGM); BGS loops on a reserved mixer channel; SE plays one-shot on the
remaining channels. Volume maps from the RPG 0..100 scale to SDL's 0..128.

## Consequences

- Games now play music and sound effects, and the interpreter's Play BGM / Play
  SE commands (now also forwarding volume/tempo) are audible.
- The gem still builds and tests without SDL: with no backend installed every
  Audio call is a graceful no-op, exercised by the `rake test` suite.
- **Pitch/tempo is accepted but not applied** — SDL_mixer offers no pitch shift
  for music or samples. Honouring it would need a resampling layer or a
  different engine.
- **MIDI depends on the SDL_mixer build.** WAV/OGG play everywhere; MIDI plays
  only when the linked SDL_mixer has a MIDI synth (e.g. Timidity/FluidSynth). A
  file that fails to load is logged once and skipped rather than crashing.
- Adds SDL2_mixer as a build dependency (nix `buildInputs`, CMake
  `find_package`/pkg-config, and the Emscripten `-sUSE_SDL_MIXER=2` port).
