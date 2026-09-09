# 127. Strip the sixel/iTerm2 terminal-image encoders for wio (and PSP)

Date: 2026-09-09

## Status

Accepted

## Context

`terminal.cxx` already excludes its own real implementation on PSP and Wio
(`#if !defined(PSP_BUILD) && !defined(WIO_TERMINAL)`), with a file-level
comment explaining why: neither target has a controlling tty, and neither
build offers a game any way to select a terminal backend in the first
place. But the two encoder files it calls into, `sixel.cxx` and
`iterm.cxx`, are separate translation units with no gate of their own --
`mrbgem.rake` compiles every `src/*.cxx` unconditionally, and these two
were never given the same treatment `terminal.cxx` gave itself.

Grepping every caller of `sixel_display_create`/`iterm_display_create`
(their only two exported symbols) turns up exactly one: `src/main.cxx`,
the desktop entry point's `--sixel`/`--iterm` CLI flags. Neither
`app/wio/src` nor `app/psp/src` calls either function -- and even if they
tried to, `terminal_display_create` (the shared plumbing both encoders
call into) is already compiled out on both targets, so the call would
fail to link regardless. Both files' real implementations were therefore
provably dead code on wio and PSP already, just not expressed at compile
time.

`iterm.cxx` is the one that matters: it defines
`STB_IMAGE_WRITE_IMPLEMENTATION`, pulling in `stb_image_write.h`'s bundled
PNG writer -- a full from-scratch DEFLATE encoder (LZ77 matching, Huffman
tree construction) plus zlib/PNG chunk framing. Nothing else in this build
needs one: `lib.cxx`'s own `stb_image.h` (`STB_IMAGE_IMPLEMENTATION`) only
ever calls `stbi_zlib_decode_malloc`/`_noheader_malloc` -- inflate, never
deflate, for loading game assets and RGSS's `Zlib.inflate`. A compressor
is a real, otherwise-unique cost this build was paying for a feature it
cannot reach.

## Decision

Gated both files' real implementations behind the identical condition
`terminal.cxx` already uses for the same reason:
`#if !defined(PSP_BUILD) && !defined(WIO_TERMINAL)`. Unlike ADR 0125/0126
(which scoped their gate to `WIO_TERMINAL` alone, a flash-budget judgment
call since PSP has headroom to spare), this one covers PSP too --
deliberately matching `terminal.cxx`'s own scope, because this is the same
kind of gate as that file's: a *capability* question (no controlling tty
on either target, so a terminal backend can never be selected there), not
a budget tradeoff. Leaving PSP linking a PNG/DEFLATE encoder its own
`terminal.cxx` already can never call into would be inconsistent with
that file's own reasoning, not a deliberate allowance the way ADR 0125's
profiler carve-out was.

The `#else` branch for each file is its one exported function, stubbed to
return `nullptr` -- matching `terminal.cxx`'s own `rgss_terminal_poll`
stub pattern exactly.

### What was verified

- Both branches of both files compile cleanly (host `g++ -std=c++17
  -Wall -Wextra`; `iterm.cxx`'s real branch produces only pre-existing
  warnings from `stb_image_write.h` itself, unrelated to this change).
- The preserved (real) branches are byte-for-byte unchanged content,
  only newly wrapped in the `#if`/`#else` (diffed directly).
- Real `arm-none-eabi-g++` cross-compile with this board's actual flags
  (`-mcpu=cortex-m4 -mfloat-abi=hard -mfpu=fpv4-sp-d16 -Os -fno-rtti`):
  - `sixel.cxx`: **2,219 -> 12 bytes of `.text`**
  - `iterm.cxx`: **16,408 -> 12 bytes of `.text`**
  - combined: **18,603-byte reduction**, larger than ADR 0125's profiler
    strip by itself.
- Confirmed (grep, repo-wide) that neither `sixel_display_create` nor
  `iterm_display_create` has any caller besides `src/main.cxx`.

### What was not verified

- No full wio/PSP firmware link (same sandbox limitation as ADR
  0125/0126) -- the isolated `.o` deltas above are the real, measured
  numbers for these two files, not a confirmed final linked-firmware
  delta. Unlike ADR 0125's profiler case, there is no float-formatting
  overlap question here to flag: `stb_image_write.h`'s DEFLATE tables and
  Huffman code are self-contained and shared with nothing else this
  build links.
- No full desktop/wasm/android rebuild; trusted on the byte-for-byte-
  unchanged preserved branches instead, same as ADR 0125/0126.

## Consequences

- A real additional flash win for both wio and PSP, zero behavior
  change -- neither board could ever reach either encoder.
- Desktop/wasm/android keep both encoders unchanged; `--sixel`/`--iterm`
  behave exactly as before there.
- `window_title.cxx` and `log_bridge.cxx` (this same directory's other
  small terminal-adjacent files) were checked and left alone: both are
  cheap function-pointer-hook shims already designed to be harmless
  no-ops on every target (including wio/PSP) rather than terminal-only
  code, so there is nothing dead to gate out of either.
