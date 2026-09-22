# 0186. Statically link the C++ runtime on the desktop Linux build

Date: 2026-09-22

## Status

Accepted

## Context

The native desktop build (`cmake -S . -B build && cmake --build build`, no
`RPGMAKER_BC2CPP`) links against roughly two dozen shared libraries resolved
from this project's own Nix flake (`ldd build/rpg_maker_clone`): SDL2,
SDL2_mixer, the GL dispatch libraries (libEGL/libGLESv2/libGLdispatch from
libglvnd), the C++ runtime (libstdc++.so.6, libgcc_s.so.1), and SDL2_mixer's
own transitive codec/audio-backend closure (libgme, libxmp, libfluidsynth,
libopusfile, libwavpack, libsndfile, libogg, libopus, libFLAC, libvorbis*,
libpulse*, libasound, libjack, libz). Every one of those paths is a Nix store
path, so a binary built this way cannot run outside this exact Nix closure —
it needs the identical library versions at the identical store paths, which no
other machine has.

"Statically link the desktop build" is not one decision but several, of very
different size and risk:

1. **The C++ runtime** (`libstdc++.so.6`, `libgcc_s.so.1`). Folding these into
   the binary is the standard, always-safe `-static-libgcc
   -static-libstdc++` GCC flag pair — no functional difference, no licensing
   concern (both carry the GCC Runtime Library Exception, written for exactly
   this use), and it removes two Nix-store-path dependencies from the
   binary's own `NEEDED` list unconditionally.
2. **SDL2 and SDL2_mixer**, and, through SDL2_mixer, its whole codec/backend
   closure. This project already vendors both as submodules (`3rd/SDL`,
   `3rd/SDL_mixer`) and already knows how to build them from source as static
   libraries — the Android branch a few lines above this decision's own does
   exactly that, with `BUILD_SHARED_LIBS OFF` and a trimmed
   `SDL2MIXER_VORBIS=STB` / `SDL2MIXER_MIDI_TIMIDITY=ON` codec profile (OGG
   via SDL2_mixer's bundled `stb_vorbis.h`, MIDI via SDL2_mixer's bundled
   TiMidity, no external codec library). Copying that profile onto the
   desktop build would remove libgme/libxmp/libfluidsynth/libopusfile/
   libwavpack/libsndfile/libogg/libopus/libFLAC/libvorbis* outright.
3. **GL** (libEGL/libGLESv2, from libglvnd) and **the OS audio backends**
   (ALSA/PulseAudio/JACK).
4. **A fully static binary** (`-static`, against a static libc).

## Decision

Do (1) now: `add_link_options("-static-libgcc" "-static-libstdc++")` for the
plain desktop Linux path only (guarded on `CMAKE_SYSTEM_NAME STREQUAL
"Linux"`, inside the existing `else()` branch that already only runs for
"not Emscripten, not Android" — i.e. never touches the wasm/Android build,
which have their own linking models, or Darwin, which has no
`libstdc++.so`/`libgcc_s.so.1` in the same sense).

Verified against the executable's own ELF `NEEDED` list (`readelf -d`, not
`ldd`, see Consequences): `libstdc++.so.6` and `libgcc_s.so.1` are gone from
the executable's own direct dependencies. `ldd` still reports both, because
SDL2_mixer's own dynamic dependency chain (libfluidsynth and libgme are both
C++ libraries, each with its own dynamic `libstdc++.so.6` need) pulls them
back in transitively — a real, separate fact this change does not and cannot
touch without also addressing (2).

Do NOT do (2) this round. Two real, unresolved problems, not merely
unfinished work:

- **Mixing static and dynamic copies of the same library in one process is a
  real hazard, not a style choice.** Vendoring SDL2 as a static archive while
  leaving `find_package(SDL2_mixer)` resolve Nix's own SDL2_mixer package
  (itself linked against Nix's *own*, separate SDL2 shared object) would put
  two independent copies of SDL2's global state in the same process — this
  project's own executable calling into the statically-linked copy directly,
  SDL2_mixer calling into the dynamically-loaded one internally — an ABI/
  symbol-interposition risk. SDL2 and SDL2_mixer have to move together, both
  built from `3rd/SDL`/`3rd/SDL_mixer`, never mixed with Nix's prebuilt ones.
- **The Android/Emscripten codec profile is a real feature reduction on
  desktop, not a free trim.** RPG Maker XP/VX/VXAce era projects are known to
  ship `.mp3` background music despite it never being the recommended format,
  and MV/MZ-era or homebrew projects could plausibly use `.flac`/`.opus`/
  tracker music the current Nix-linked SDL2_mixer already plays. Silently
  dropping MP3/FLAC/Opus/WavPack/tracker/chiptune support to shave dependency
  count is a product decision this ADR does not make unilaterally. GME
  (console chiptune emulation) and XMP (tracker formats) are the one pair
  genuinely safe to drop without asking — no RPG Maker era ships either format
  — but that alone does not justify rebuilding SDL2_mixer from source.

Do NOT do (3): libglvnd's `libEGL`/`libGLESv2` are ICD *dispatch* libraries by
design — they `dlopen()` the real vendor GPU driver at run time (Mesa's
llvmpipe here) so the same binary works against whatever driver is actually
installed; there is no meaningful "static" form of a dispatch mechanism whose
entire purpose is late driver binding. ALSA/PulseAudio/JACK are the same
story for audio: every Linux game that ships a "statically linked" binary
(the Steam runtime included) still dynamically loads its audio backend,
because the backend that exists on the *target* machine is not known at
build time. Neither is a gap in this decision; both are inherent to how
Linux audio/graphics portability actually works.

Do NOT attempt (4), a fully static (`-static`) executable, speculatively.
`glibc`'s static form has known, real gaps (NSS-based hostname/user lookups
silently stop working; DNS resolution can break depending on `/etc/nsswitch`)
that would need to be worked around specifically, if this project ever
resolves a hostname or a local user at run time (git describe at configure
time is unaffected; nothing checked in this pass established whether any
runtime code path does). Nix's own `pkgsStatic` (verified reachable from this
flake's pinned `nixpkgs`, `pkgsStatic.SDL2`/`pkgsStatic.SDL2_mixer`/
`pkgsStatic.{libvorbis,flac,libxmp,fluidsynth,opusfile,wavpack,libsndfile}`
all evaluate and none carry `meta.broken`) is the realistic path if this is
ever pursued for real — nixpkgs already carries the *entire* transitive
static-variant closure rather than this project hand-vendoring eight codec
libraries' own build systems (that closure is the whole point of
`pkgsStatic`) — but building it end to end was out of scope
for this pass (untested for actual build success, only confirmed evaluable
metadata; likely one to several days once cache misses and this project's
own CMake/mruby/quickjs/effekseer build is retargeted at it).

## Consequences

- The desktop Linux binary's own `NEEDED` ELF entries no longer include
  `libstdc++.so.6`/`libgcc_s.so.1`. `ldd` (which reports the full transitive
  closure, not just this binary's direct dependencies) still lists both,
  brought back by SDL2_mixer's own codec closure — a real, honest limit of
  what a link-flag-only change can achieve, not a sign the change did
  nothing. Verify future changes here with `readelf -d build/rpg_maker_clone
  | grep NEEDED`, not `ldd`, for the same reason.
- No functional, licensing or cross-target change: Emscripten and Android
  keep their own, already-correct linking setups untouched; the flags are
  Linux-only and standard GCC practice.
- The desktop binary is *closer* to portable, not portable yet — it still
  needs Nix's own SDL2/SDL2_mixer/libglvnd/ALSA/PulseAudio/JACK/glibc at the
  same store paths. A genuinely redistributable desktop binary needs, at
  minimum, the SDL2+SDL2_mixer-from-source work above (with a codec-parity
  decision made explicitly, not defaulted), and would still legitimately
  leave GL/audio-backend discovery dynamic by design.
- Follow-up work, roughly ordered by value/risk: (a) vendor-build SDL2 +
  SDL2_mixer together from `3rd/SDL`/`3rd/SDL_mixer` with an explicit,
  reviewed codec profile (drop GME/XMP only, keep or deliberately drop
  MP3/FLAC/Opus/WavPack after checking whether any committed/sample project
  data actually uses them); (b) evaluate `pkgsStatic` as the lower-effort
  route to the same codec-parity static SDL2_mixer, which sidesteps
  hand-vendoring the codec libraries' own build systems; (c) a full `-static`
  binary only if a genuine field requirement for glibc-free portability shows
  up, with the NSS/DNS gaps checked against this project's actual runtime
  network/user-lookup surface first.
