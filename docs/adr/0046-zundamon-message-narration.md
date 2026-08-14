# 46. Zundamon (ずんだもん) message-window narration via bundled VOICEVOX CORE

Date: 2026-08-14

## Status

Accepted

## Context

A request came in to read the rpg2k message window's text aloud in Zundamon's
voice ("ずんだもん読み上げ") as an accessibility/flavour feature. That needs a
real Japanese speech synthesizer somewhere in the pipeline; three shapes were
considered:

- **A local VOICEVOX Engine over HTTP.** The usual way "ずんだもん読み上げ"
  integrations work: POST text to a VOICEVOX Engine process the player runs
  separately (`/audio_query` then `/synthesis`, default
  `http://127.0.0.1:50021`) and play back the WAV it returns. Needs a new
  network-client dependency (this engine links no HTTP client anywhere today)
  and a separate process the player has to keep running; nothing works
  offline or in a packaged build with nobody around to start an engine.
- **A pluggable interface with no real backend wired up.** Cheap, but leaves
  the game silent — not what was asked for.
- **Bundle a full synthesis stack.** VOICEVOX CORE (the same inference engine
  the reference Engine wraps) ships as a small, dlopen-able native library
  with per-character voice models distributed separately, all under open
  licenses. Heavier to integrate than an HTTP call, but works fully offline,
  adds no new build-time dependency, and needs nothing else running.

## Decision

**Bundle VOICEVOX CORE, dlopen'd at run time, never linked at build time** —
the same posture this engine already takes with SDL_mixer's MIDI patch set
(ADR 0026): an optional, downloaded run-time asset that a build can simply
not have.

- `scripts/download-voicevox-zundamon.bash` fetches four pinned GitHub
  release assets into `assets/voicevox/` (git-ignored, ~90 MiB — see
  `assets/voicevox/README.md` for exactly what and why): VOICEVOX CORE's C
  API library, its ONNX Runtime, the Open JTalk dictionary it uses for
  Japanese text analysis, and **one voice model** — Zundamon's `0.vvm`
  (style id 3, "ノーマル") from `VOICEVOX/voicevox_vvm` — rather than that
  project's whole multi-character model pack.
- `src/voicevox_tts.cxx` `dlopen()`s `libvoicevox_core.so` and `dlsym()`s the
  ~10 C API entry points it needs against a hand-trimmed, committed mirror of
  the real header (`include/voicevox_core_capi.hxx`), so **the engine builds
  identically whether or not the assets are present**. With nothing
  downloaded, `RGSS::Tts.available?` is false and every call is a no-op —
  exactly `RGSS::Audio.midi_available?`'s shape for a missing patch set.
- The feature is **opt-in**, `--zundamon_tts` (off by default): loading an
  ONNX Runtime session costs real startup time and the assets are not
  committed, so a released game or an existing CI run is unaffected either
  way. Passing the flag with no assets installed just logs why and runs
  silently — never a crash, never a hard requirement.
- `RGSS::Tts` (mruby-rgss, mirroring `RGSS::Audio`'s
  gem/executable split — see `include/rgss_audio.hxx`'s own header comment)
  exposes `speak(text)` / `available?` / `stop` through a plain C function
  table (`include/rgss_tts.hxx`) so the gem itself never depends on VOICEVOX
  CORE, SDL or `dlopen` — it stays buildable for the terminal-only,
  Emscripten and standalone `rake test` targets exactly as before.
- **rpg2k's message window is the only caller.** `open_message` in
  `mruby-rpg2k/mrblib/scene/map.rb` already computes `plain` — each line's
  text with `\v[n]`/`\n[n]`/colour codes fully resolved, the same string the
  typewriter reveal counts characters against — and hands the joined page to
  `RGSS::Tts.speak` once, when a Show Text page opens (not per revealed
  character, and not for a bare Show Choices window).
- Synthesized audio plays through **SDL_mixer directly** (`Mix_PlayChannel`
  on an unreserved channel, the same pool `Play SE` uses), not through
  `RgssAudioBackend`: at most one utterance is ever in flight, since a new
  page's narration replaces whatever the previous page started, so the
  module tracks a single outstanding `Mix_Chunk` rather than reusing
  `RgssAudioBackend.se_play_mem`'s cache-forever-by-name design (which would
  otherwise leak one chunk per distinct line of dialogue for the life of the
  process).
- **Desktop native only** (Linux/macOS `dlopen`). VOICEVOX CORE ships no
  Emscripten, PSP or Wio Terminal port, so `src/voicevox_tts.cxx` compiles to
  two no-op functions there via `#if !defined(__EMSCRIPTEN__) &&
  (defined(__linux__) || defined(__APPLE__))`, and the one `add_executable`
  target shared by the native and Emscripten builds needs no conditional
  source list.

## Consequences

- **Licensing carries forward, not just downward.** Zundamon's voice model
  requires crediting **"VOICEVOX:ずんだもん"** wherever generated audio is
  used, commercial or not (`assets/voicevox/models/TERMS.txt`, written by the
  download script; full terms at
  [voicevox_vvm's README](https://github.com/VOICEVOX/voicevox_vvm/blob/main/README.md)).
  That obligation belongs to whoever ships a build with `--zundamon_tts`
  enabled, the same way it would apply to a video made with the reference
  VOICEVOX Engine — the engine does not enforce or automate it.
- **One voice, one style, no runtime choice.** `kZundamonNormalStyleId = 3`
  is a compile-time constant in `src/voicevox_tts.cxx`. Supporting another
  character or style means downloading another `.vvm` and either adding a
  config knob or a second bundled model; neither exists yet.
- **Windows is unsupported**, matching this engine's existing scope (no
  `CMakeLists.txt` branch targets it at all — Windows-under-RPG_RT is only
  ever exercised via wine for render-parity comparisons, never as a native
  build of this engine). Adding it means an `LoadLibraryExW`/`GetProcAddress`
  path alongside the POSIX `dlopen` one.
- **GPU acceleration is out of scope.** `VOICEVOX_ACCELERATION_MODE_CPU` is
  hard-coded; VOICEVOX CORE's CUDA/DirectML builds need the separate
  `voicevox_additional_libraries` archive the download script does not fetch.
- **No CI job downloads these assets.** Unlike the MIDI patch set and the
  default font, `.github/workflows/build.yml` does not call
  `download-voicevox-zundamon.bash` — the assets are large, span three
  external GitHub organizations, and the feature is opt-in flavour rather
  than something most CI checks exercise. `scripts/check_voicevox_assets.rb`
  still validates the layout when the assets *are* present (a developer's
  local checkout) and exits 0 cleanly when they are not, the same shape as
  `check_default_font.rb`.
- **The CI CORS-proxy cache (`CORS_PROXY_URL`, ADR 0042/0043) does not yet
  allow these hosts.** The download script routes through it exactly like
  its siblings, so once someone wants this feature exercised in a
  network-restricted CI environment, the Cloudflare Worker's `ALLOWED_HOSTS`
  needs `github.com` (already implied for other download scripts) to reach
  release assets on `VOICEVOX/voicevox_core`, `VOICEVOX/onnxruntime-builder`,
  `VOICEVOX/voicevox_vvm` and `r9y9/open_jtalk`.
