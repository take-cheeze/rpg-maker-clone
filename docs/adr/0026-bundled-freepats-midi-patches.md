# 26. Downloaded FreePats patch set for MIDI playback

Date: 2026-08-05

## Status

Accepted

Amends [6. Audio playback with SDL_mixer](0006-audio-sdl-mixer.md), whose
consequences left MIDI conditional on the SDL_mixer build.

## Context

ADR 0006 wired `RGSS::Audio` onto SDL_mixer and left one channel of the RPG2000
format matrix unresolved: "**MIDI depends on the SDL_mixer build.** WAV/OGG play
everywhere; MIDI plays only when the linked SDL_mixer has a MIDI synth." That
caveat mattered more than it looked, because RPG2000-era projects ship most of
their BGM as `.mid` — the exact games this engine targets were the ones running
silent.

The diagnosis was narrower than "no synth". SDL_mixer already *contains* a
synth: a TiMidity codec in `src/codecs/timidity/`. What it lacked was
instrument data. A MIDI file carries note events and no audio, so TiMidity needs
a config naming a GUS patch (`.pat`) per General MIDI program. With none, a
`.mid` loads successfully and then plays silence — the worst failure shape,
since nothing errors.

Options for supplying a synth:

- **Configure SDL_mixer's built-in TiMidity** — no new linking; needs a patch
  set and a config path.
- **Build the vendored `3rd/timidity`** (TiMidity++ 2.15.0, a submodule at the
  time of this decision and since removed) — 85 `.c` files of autoconf-driven
  *application*, not a library: it would need a hand-written `config.h`, a
  `Mix_HookMusic` bridge, and it is GPL, which would place the engine binary
  under GPL terms. It would still need the same patch data.
- **FluidSynth + a SoundFont** — a new link dependency and an equally large
  asset, for a synth SDL_mixer only reaches through a second code path.

Options for the instrument data, which every synth needs:

- **Commit a patch set** — works on a fresh clone with no external step, at the
  cost of ~32 MiB in the repository, permanently and for every clone.
- **Download it with a script** — the repository stays small and nothing here
  redistributes GPL sample data; the cost is a setup step, which this repository
  already has seven of (`scripts/download-*.bash`, `scripts/rtp_install.bash`)
  and a CI barrier that waits on them.
- **Depend on a system/nix package** — smallest of all, but MIDI then works only
  where someone installed the right package, which is the status quo ADR 0006
  already found unsatisfying.

## Decision

Drive **SDL_mixer's built-in TiMidity**, and install the **FreePats General MIDI
patch set** into `assets/timidity/` with `scripts/download-freepats.bash`
(config plus 128 `.pat` files, ~32 MiB, git-ignored).

The script fetches the version-pinned `freepats` npm tarball — immutable and
checksummable, where upstream serves a rolling archive — verifies a pinned
SHA-256 before unpacking, generates `timidity.cfg` from FreePats' `freepats.cfg`
with an explanatory header, and is idempotent. CI runs it as a background step
gated by the existing download barrier.

- `src/sdl_audio.cxx` gains `init_midi_config()`, run before `Mix_OpenAudio()`
  because SDL_mixer initialises the TiMidity codec while opening the device and
  reads its config only at that point. It resolves the first config that exists
  from: an existing `TIMIDITY_CFG` (the user's override, left untouched);
  `assets/timidity/` next to the executable; the installed
  `share/rpg-maker-clone/timidity/`; a configure-time path into the source tree
  (`RGSS_TIMIDITY_CFG_SOURCE`, so build-tree runs work without copying 32 MiB);
  `/timidity` for the Emscripten mount; then the usual system paths. It hands
  the result to `Mix_SetTimidityCfg()` (SDL_mixer ≥ 2.6) *and* exports
  `TIMIDITY_CFG` without overwriting, which is the only mechanism older 2.x
  releases have.
- Availability is reported rather than assumed: a new `midi_available` entry on
  the `RgssAudioBackend` table surfaces as `RGSS::Audio.midi_available?`, and
  `Audio.setup_midi` warns once instead of unconditionally, only when MIDI would
  in fact be silent.
- `scripts/check_timidity_patches.rb` runs as the `timidity_patches` CTest and
  fails if `timidity.cfg` references a patch that is missing or empty, or if an
  installed `.pat` is never referenced. TiMidity drops an unresolvable
  instrument silently at play time, so this class of bug is otherwise invisible.
  It reports and passes when the patches were simply never downloaded, which is
  a normal state for a fresh checkout.
- Nothing about the build depends on the download having happened:
  `RGSS_TIMIDITY_CFG_SOURCE` is baked in unconditionally and probed at run time,
  so configuring before fetching does not require a re-configure, and the two
  steps stay order-independent in CI.
- The vendored `3rd/timidity` submodule is not built. Recording it here as a
  rejected option rather than an implied future direction is what made it
  removable, and it was subsequently deleted (PR #312) — it had never been
  referenced by any build.

## Consequences

- MIDI BGM/ME are audible after one setup command, which is what RPG2000
  projects actually need. `Audio.midi_available?` lets scripts and logs
  distinguish "no patches" from "playing".
- **The repository stays small** and carries no GPL sample data. The cost is a
  setup step that can be skipped: someone who builds without running the script
  gets silent MIDI, and the run-time warning plus `Audio.midi_available?` are
  what tell them why.
- **The patches are GPL v2** (`assets/timidity/LICENSE`, installed by the
  script). They are data read at run time, not code linked into the engine, so
  the engine binary is not itself placed under the GPL — but anything that
  packages `assets/timidity` for redistribution must carry that licence with it.
- **The download is a network dependency**, pinned by version and SHA-256 so it
  cannot drift silently. A corrupt or truncated cache is re-fetched rather than
  trusted; a checksum mismatch fails loudly instead of feeding a synthesiser
  garbage that would surface as confusing audio errors.
- **The browser build needed two things, not one.** Emscripten's SDL2_mixer port
  compiles one decoder per requested format and defaults to
  `SDL2_MIXER_FORMATS=["ogg"]`, so a stock `-sUSE_SDL_MIXER=2` build has no MIDI
  decoder at all and preloading patches into it would have achieved nothing.
  The build now asks for `-sSDL2_MIXER_FORMATS=ogg,mid` (which compiles the port
  with `-DMUSIC_MID_TIMIDITY`, the same codec the native build uses) *and*
  mounts the patch set at `/timidity` via `-DWASM_MIDI_PATCHES=ON`. CI passes
  that flag, so the deployed and preview pages both play MIDI — at the cost of
  ~32 MiB in `index.data`. Dropping the flag gives a slimmer page whose `.mid`
  playback is silent; the decoder itself is small and stays in either way.
  The preload is deliberately not guarded on the directory existing, matching
  `WASM_SAMPLE_DIR`: the download runs concurrently with the configure and is
  awaited by a barrier before the link.
- **FreePats covers 72 of 128 melodic programs.** A MIDI selecting a missing
  program sounds thinner than it would with a fuller set; `TIMIDITY_CFG` is the
  documented escape hatch.
- **MIDI remains BGM/ME-only.** SE and BGS play as mixer samples via
  `Mix_LoadWAV`, which never synthesises MIDI regardless of patch configuration.
  That case now logs that explicitly instead of a bare decode error.
- Pitch/tempo is still accepted and not applied (ADR 0006), which stays visible
  on MIDI, where RPG2000 games do vary BGM tempo.
