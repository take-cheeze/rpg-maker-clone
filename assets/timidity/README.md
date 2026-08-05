# MIDI instrument patches (FreePats)

This directory holds the instrument samples that make MIDI music audible. It is
empty in a fresh checkout — everything except this README is downloaded:

```sh
./scripts/download-freepats.bash
```

## Why it is needed

RPG2000-era projects ship most of their music as `.mid`. A MIDI file carries
only note events — "program 0, note 60, velocity 90" — and no audio, so playing
one needs a synthesiser *and* a set of instrument samples.

SDL_mixer already contains the synthesiser (a TiMidity codec). What it lacks is
the samples. Without them a `.mid` loads *successfully* and then plays silence,
which is the worst failure shape: nothing errors, the music is just missing.

## What the script installs

| Path            | What it is                                                |
| --------------- | --------------------------------------------------------- |
| `timidity.cfg`  | Generated. Maps GM programs / drum notes onto the patches  |
| `Tone_000/`     | 72 melodic instrument patches (GM bank 0)                  |
| `Drum_000/`     | 56 percussion patches (GM drumset 0)                       |
| `LICENSE`       | GNU GPL v2 — the terms the patch set is distributed under  |

A `.pat` is a Gravis Ultrasound patch: recorded audio for one instrument plus
the metadata TiMidity needs to play it musically — root pitch, loop points so a
held note sustains, volume envelopes, and the key range the sample covers.
`timidity.cfg` is the lookup table binding GM program numbers to those files.

## Provenance and licensing

The patches are the **Old FreePats General MIDI sound set**, fetched from the
`freepats` npm package (v1.0.3), which republishes the set from
<https://freepats.zenvoid.org/>. The npm tarball is used because it is
immutable, version-pinned and checksummable, where the upstream site serves a
rolling archive; the script verifies a pinned SHA-256 before unpacking.

FreePats is distributed under the **GNU GPL v2**. These are data files read at
run time, not code linked into the engine, so using them does not place the
engine binary under the GPL — but they are not committed here, and anything that
*does* redistribute them must carry `LICENSE` alongside.

Only `timidity.cfg` is modified, and only by generating it: the script prepends
a comment header to FreePats' `freepats.cfg` body, which is otherwise verbatim.
Every `.pat` is byte-for-byte upstream.

## Coverage and overrides

FreePats is not a complete General MIDI set — 72 of the 128 melodic programs are
present. A MIDI selecting a missing program plays that part with whatever
TiMidity falls back to, so some tracks sound thinner than they would with a
fuller set.

To use a different patch set, point `TIMIDITY_CFG` at its config file.
`src/sdl_audio.cxx` leaves an existing `TIMIDITY_CFG` untouched, so it always
wins over anything installed here.

## Keep the layout together

`timidity.cfg` refers to its patches by relative path, and SDL_mixer's TiMidity
adds the config file's own directory to the patch search path. So
`timidity.cfg`, `Tone_000/` and `Drum_000/` must stay siblings wherever this
directory is copied or installed.
