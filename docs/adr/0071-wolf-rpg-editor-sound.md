# 71. WOLF RPG Editor Sound(140): playing a real SE by filename

Date: 2026-09-07

## Status

Accepted

## Context

`Sound`(140) -- "音楽や効果音を再生します" (help/04ev_sound.html) -- is one
event command covering BGM/BGS/SE playback, preloading, freeing unused
memory, three different ways to name what to play (a literal filename, a
system-database entry, or a variable holding one), and per-kind extras
(fade time, mid-track position, pan, volume, frequency, loop points, BGS
channels, SE delay/channels, a handful of documented "hidden features" like
string-variable-embedded volume/frequency overrides and OGG `LOOPSTART`
tags) -- far more surface than one slice should take on at once.

As with `Choices`(102) (ADR 0070), the wolfrpg-map-parser crate's own
`SoundCommand` parses fixed-width sub-fields (`options: u8`,
`systemdb_entry: u16`, `sound_type: u8`) that do not obviously correspond to
this reader's own generic `arg(N)` (int32) view -- but here they turn out to
be *exactly* one 4-byte `arg(0)`, byte for byte: byte 0's low nibble is the
crate's own `ProcessType` (0 normal playback, 1 preload, 3 free unused
memory), byte 0's high nibble its `Operation` (0 BGM, 1 BGS, 2 SE), bytes
1-2 its `systemdb_entry` (little-endian), byte 3 its `SoundType` (0 a
direct system-database selection, 1 a variable naming one, 2 a literal or
string-variable filename) -- confirmed by decomposing every real `Sound`
command in the sample game's own data (30 of them) byte by byte and
checking each decoded combination against what the surrounding script
actually does: `0x02000020` (process=Playback, operation=SE, sound_type=
Filename) on every call whose own string argument is a real `.ogg` path;
`0x00FFFF00` (operation=BGM, sound_type=DBEntry, systemdb_entry=`0xFFFF` as
signed 16-bit = -1, the manual's own documented "(停止)" stop sentinel)
right after a `256` (`systemdb_entry=1`) call that starts the same track,
in the sample game's own end-credits event; `0x01000000` (operation=BGM,
sound_type=Variable) alongside a *separate* int argument holding the actual
variable reference, confirming Variable mode's index is not packed into
`systemdb_entry` at all, unlike the crate's own struct layout might suggest.

The trailing arguments' own layout is confirmed only for the one case this
ADR implements: `Filename`+`SE`+`Playback` real calls all carry 6 or 7
arguments, with `arg(4)`/`arg(5)` varying from their 100/100 default in at
least one real call (`map1 ev#19`'s own volume=60/frequency=70 SE) --
proving those two slots, and nothing about the others (which stay 0 in
every real example, so nothing rules out them being pan, an SE delay, or
something else this reader has not placed).

## Decision

- `Wolf::Interpreter#exec_sound` decodes `arg(0)` as above and only acts on
  `Playback`+`SE`+`Filename` with 6 or 7 arguments; everything else --
  BGM/BGS, a system-database or variable sound source, preload/free-memory,
  any other argument count -- is logged and skipped rather than guessed.
- A filename that is itself a WOLF string-interpolation escape (a real,
  common shape in the sample game's own Common Events -- `"\cself[9]"`,
  meaning "the current common event's own self-variable 9, as a string")
  is skipped too: no command in this interpreter expands those escapes yet
  (`Message`(101) does not either), so resolving one correctly is a
  separate, larger feature.
- `WolfRPG::MapScene#play_se(path, volume, pitch)` calls
  `RGSS::Audio.se_play`, prefixing `path` with `Data/` the same way
  Picture(150)'s own file loading already does (real command dumps confirm
  the identical convention: `"SE/System_Get2_wolf.ogg"`,
  `"SystemFile/SE_Get.ogg"`) -- but passed as a `GAME_DIR`-relative string
  rather than joined into an absolute path, since `RGSS::Audio`'s own
  `resolve` (unlike `RGSS::Bitmap.new`) already does its own
  `GAME_DIR`/`RTP_DIR` search and only needs the `Data/` prefix added on
  top, which `GAME_DIR` itself does not know about.

## Consequences

- Every real "play this SE by its own filename" call in the sample game
  now actually plays -- 13 of them once string-interpolated filenames and
  the one 8-argument outlier (a pan-variable demo whose own trailing
  argument layout is not confirmed) are excluded.
- BGM/BGS playback, system-database and variable sound sources, and every
  documented "hidden feature" remain unimplemented, logged rather than
  guessed -- a natural, well-scoped follow-up once real examples of each
  turn up to cross-check the crate's own struct fields against (BGM/BGS's
  own `map1 ev#13`/`CE#188` calls are the obvious next real data to use for
  that, given both are already dumped and byte-decoded above).
