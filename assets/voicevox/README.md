# Zundamon text-to-speech (VOICEVOX CORE)

This directory holds the offline synthesis stack behind `--zundamon_tts`
(rpg2k message-window narration in Zundamon's voice, `src/voicevox_tts.cxx`).
It is empty in a fresh checkout — everything except this README is
downloaded:

```sh
./scripts/download-voicevox-zundamon.bash
```

## Why it is needed

Reading a Show Text page's text aloud needs a real Japanese speech
synthesizer, not just an audio backend. VOICEVOX CORE is that synthesizer: a
native library (Rust, built as a C API) that turns UTF-8 text into a WAV
waveform in a chosen character's voice, running an ONNX Runtime model
entirely offline — no VOICEVOX Engine process, no network access at play
time.

`src/voicevox_tts.cxx` `dlopen()`s the pieces below at run time; none of this
is a build-time (link-time) dependency, the same way SDL_mixer's MIDI patch
set (`assets/timidity`) is an optional run-time asset rather than a linked
library. With nothing installed here, `RGSS::Tts.available?` is simply false
and the game runs exactly as it would without this feature.

## What the script installs

| Path                              | What it is                                             |
| ---------------------------------- | ------------------------------------------------------- |
| `core/lib/libvoicevox_core.so`     | VOICEVOX CORE's C API shared library                    |
| `core/include/voicevox_core.h`     | Its full public header (reference only — see below)     |
| `core/LICENSE`                     | MIT — VOICEVOX CORE's own license                       |
| `onnxruntime/lib/libvoicevox_onnxruntime.so` | The ONNX Runtime build CORE loads for inference |
| `onnxruntime/TERMS.txt`            | Its usage terms                                         |
| `dict/open_jtalk_dic_utf_8-1.11/`  | Open JTalk's UTF-8 dictionary (accent/pronunciation analysis for Japanese text) |
| `models/0.vvm`                     | Zundamon's voice model — 4 styles, see below            |
| `models/TERMS.txt`                 | Zundamon's usage terms — see Licensing below            |

`0.vvm` is not one voice: it carries four of Zundamon's styles, selectable at
run time with `--zundamon_tts_style` (default 3, ノーマル/normal):

| Style id | Name (Japanese / English) |
| -------- | -------------------------- |
| 3        | ノーマル / normal (default) |
| 1        | あまあま / sweet            |
| 7        | ツンツン / curt              |
| 5        | セクシー / sultry            |

`--zundamon_tts_speed`/`_pitch`/`_intonation`/`_volume` further tune the
AudioQuery scale factors VOICEVOX itself exposes (see `docs/adr/0046-…md`);
these apply on top of whichever style is selected. Reaching an entirely
different VOICEVOX character (not just another Zundamon style) needs its own
`.vvm`, which this script does not fetch.

`include/voicevox_core_capi.hxx` is a small, hand-trimmed mirror of
`core/include/voicevox_core.h` covering only the ~10 declarations
`src/voicevox_tts.cxx` calls via `dlsym()`; it is committed (it costs nothing
to build against, unlike the library itself) so the engine compiles with or
without this directory present.

## Provenance and licensing

All four pieces are pinned GitHub release assets, so the bytes are immutable
and checksummable — the script verifies a SHA-256 for each before installing
it. The CORE, ONNX Runtime and VVM versions are pinned *together*: a `.vvm`
file's format version only loads on a CORE build new enough to understand it,
and CORE expects a specific ONNX Runtime build — see the version-pinning note
at the top of `scripts/download-voicevox-zundamon.bash` before bumping any
one of them on its own.

- **VOICEVOX CORE** — [`VOICEVOX/voicevox_core`](https://github.com/VOICEVOX/voicevox_core),
  MIT licensed.
- **ONNX Runtime** — [`VOICEVOX/onnxruntime-builder`](https://github.com/VOICEVOX/onnxruntime-builder)'s
  CPU build (`voicevox_onnxruntime`); its own terms travel in
  `onnxruntime/TERMS.txt`.
- **Open JTalk dictionary** — [`r9y9/open_jtalk`](https://github.com/r9y9/open_jtalk),
  the standard UTF-8 dictionary release also used by the reference VOICEVOX
  Engine.
- **Zundamon's voice model** — [`VOICEVOX/voicevox_vvm`](https://github.com/VOICEVOX/voicevox_vvm),
  the single `0.vvm` file covering the "ノーマル" style (style id 3), not the
  whole multi-character model pack.

**Audio generated with Zundamon's voice model must be credited as
"VOICEVOX:ずんだもん"**, in commercial or non-commercial use alike — this is a
property of the voice model itself (see `models/TERMS.txt` after
downloading, or
[voicevox_vvm's README](https://github.com/VOICEVOX/voicevox_vvm/blob/main/README.md)),
not a repository-specific requirement, and it applies to any game built with
`--zundamon_tts` the same way it would apply to a video made with the
reference VOICEVOX Engine.

## Platform coverage

Desktop native only (Linux/macOS `dlopen`); Emscripten, PSP and Wio Terminal
builds compile the same source file down to two no-op functions (VOICEVOX
CORE ships no port for any of the three). `--zundamon_tts` on one of those
builds logs why and the game runs silently, same as a native build with
nothing downloaded here.
