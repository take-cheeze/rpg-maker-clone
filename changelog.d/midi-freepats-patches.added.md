- **MIDI music now plays.** RPG2000 projects ship most of their BGM as `.mid`,
  which carries note events but no audio, so it needs a synthesiser *and* an
  instrument set. SDL_mixer already had the synthesiser (its built-in TiMidity
  codec) but no instruments, so a `.mid` loaded successfully and then played
  silence. New `scripts/download-freepats.bash` installs the FreePats General
  MIDI patch set into `assets/timidity/` (128 GUS patches, ~32 MiB, git-ignored,
  GPL v2 — see `assets/timidity/README.md`), pinned by version and verified
  against a SHA-256 before unpacking. `src/sdl_audio.cxx` resolves it before
  opening the audio device and hands it to SDL_mixer via `Mix_SetTimidityCfg()`
  and the `TIMIDITY_CFG` environment variable. Lookup order: an existing
  `TIMIDITY_CFG` (the user's own patch set always wins), `assets/timidity` next
  to the executable, the installed `share/rpg-maker-clone/timidity`, the source
  tree, the Emscripten `/timidity` mount, then system paths. See ADR 0026.
- `RGSS::Audio.midi_available?` reports whether a patch set was resolved, so
  "MIDI is silent" is distinguishable from "MIDI is playing".
  `Audio.setup_midi` now warns only when MIDI would in fact be silent, instead
  of warning unconditionally as an unimplemented stub.
- A MIDI passed to `se_play`/`bgs_play` now logs that MIDI is BGM/ME-only rather
  than a bare decode failure: SE and BGS play as mixer samples, which SDL_mixer
  never synthesises MIDI for, however the synth is configured.
- New `timidity_patches` test (`scripts/check_timidity_patches.rb`) fails the
  build if `timidity.cfg` names a patch that is missing or empty, or if an
  installed patch is unreferenced — TiMidity drops an unresolvable instrument
  silently at play time, so this would otherwise ship unnoticed. It skips
  cleanly when the patches were never downloaded.
- **MIDI plays in the browser build too.** Emscripten's SDL2_mixer port compiles
  one decoder per requested format and defaults to OGG-only, so a stock
  `-sUSE_SDL_MIXER=2` build had no MIDI decoder at all; the build now asks for
  `-sSDL2_MIXER_FORMATS=ogg,mid`, which compiles the port with
  `-DMUSIC_MID_TIMIDITY`. CI configures the wasm page with
  `-DWASM_MIDI_PATCHES=ON`, mounting the patch set at `/timidity` (~32 MiB of
  `index.data`); drop the flag for a slimmer page whose `.mid` playback is
  silent.
