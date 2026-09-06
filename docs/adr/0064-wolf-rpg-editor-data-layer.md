# 64. WOLF RPG Editor (Woditor) data layer and map-exploration runtime

Date: 2026-09-06

## Status

Accepted

## Context

The engine covers the LCF makers (RPG Maker 2000/2003), the RGSS makers
(XP/VX/VX Ace) and the JavaScript makers (MV/MZ). **WOLF RPG Editor** (WOLF
RPGエディター, "ウディタ"/Woditor) is a fourth, unrelated family: a free
Japanese tool by SmokingWOLF, widely used for doujin RPGs and popular enough
that several commercial and well-known freeware titles ship on it. It has no
scripting language to host — a project's logic is entirely the fixed,
numbered event-command set the editor exposes (roughly a hundred commands,
heavily parametrised), interpreted by the closed-source `Game.exe`. So unlike
MV/MZ (embed the real JS engine) or XP/VX/VX Ace (run the game's own RGSS
scripts), the only route in is the one `mruby-rpg2k` took against LCF:
reimplement the runtime against the data.

No open-source reimplementation exists to build on. The one working
alternative, "Browser Woditor" by ruka/rikka (built with SmokingWOLF's
permission), is closed-source. `Reincarnate` decompiles the format into an
intermediate representation but stops short of a runtime. What does exist,
and what this data layer leans on to reconstruct the (undocumented) file
formats, is three independent readers that agree with each other —
[wolftrans](https://github.com/elizagamedev/wolftrans) (Ruby),
[WolfTL](https://github.com/Sinflower/WolfTL) (C++) and the
[wolfrpg-map-parser](https://crates.io/crates/wolfrpg-map-parser) crate
(Rust) — plus the MIT-licensed Kaitai Struct descriptions in
[djytw/wolf-rpg-formats](https://github.com/djytw/wolf-rpg-formats), the
closest thing to a published spec. None of the three is byte-identical to
what a current editor writes (their comments disagree on several "unknown"
fields), so the true test is the fourth source: the sample game the editor's
own official package bundles, fetched by
`scripts/download-wolfrpg-sample.bash` from SmokingWOLF's own GitHub release
(`smokingwolf/tool_wolf_rpg_editor`) — a genuine, freely redistributable
`Data/` tree straight from the tool's author, the same role Nepheshel/OpenGame
play for the LCF/XP layers.

Two format eras matter for a released game today: **2.2x** (Shift_JIS
strings, uncompressed bodies) and **3.5+** (UTF-8 strings — a single 0x55
byte replaces a 0x00 in every magic number — with the CommonEvent.dat,
`*DataBase.dat` and `.mps` bodies each LZ4-block-compressed after their
header). 3.0–3.4 sit in between (UTF-8, uncompressed) and are handled by the
same code path as 2.2x's uncompressed bodies. Archived, Pro-protected
releases (AES/ChaCha, and from 3.5 a key that is not even stored in the game)
are out of scope and refused with a clear error rather than silently
mis-parsed.

## Decision

Add **`mruby-wolf`**, a new mrbgem alongside `mruby-lcf`/`mruby-rpg2k`,
layered the same way:

- **`wolf.rb`** — the shared byte-level primitives, written in the
  mruby/CRuby common subset (no `String#unpack` directives beyond what both
  provide, no encoding API — the same discipline `mruby-lcf`'s `read_ber`
  follows, since a 32-bit word is folded to its signed value arithmetically
  rather than via `pack`/`unpack`, for the same 32-bit-`mrb_int` reason
  documented in AGENTS.md): a `Reader` (ints, length-prefixed strings, byte
  arrays, marker verification), a from-scratch **LZ4 block decoder** (no
  frame header — just the token/literal/match records DxLib's compressor
  writes), and the v2 3-seed XOR cipher (`Wolf::Crypt.v2`, the same
  MSVC-`rand()`-keystream construction `mruby-lcf`'s own save-file crypto
  documents, independently confirmed here against WolfTL's C++).
- **`data.rb`** — one class per file: `GameDat`, `MapTree`, `TileSetData`
  (+ `TileFlags`, decoding the editor's passability/priority/counter bits),
  `Database` (the three databases: user/changeable/system — one schema
  reader shared across `DataBase`/`CDataBase`/`SysDatabase`), `CommonEvents`,
  `Command` (the shared event-command decoder, common to map events and
  common events, including the trailing move-route block a "動作指定"
  command carries), and `Map` (tile layers + events + pages). `Project` ties
  a directory together the way a released game needs it: `Game.dat` for the
  screen/tile settings, `MapTree.dat` plus the system database's map-settings
  table to turn a map id into a `.mps` path, and the system database's
  position list for the New-Game start point.
- **`runtime.rb`** — the boot shell, `WolfRPG` (named apart from the `Wolf`
  data-layer module, the same way `RPG2k`/`RPGXP`/`RPGVX` sit beside their
  own gems). It reads the project, sizes the screen from `Game.dat` (WOLF RPG
  Editor games ship at whatever resolution the "ゲームの基本設定" dialog
  picked — 320x240 doubled, 640x480, or any of several 16:9 presets — not one
  fixed size per maker the way XP/VX are), and opens a walkable view of the
  New-Game start map: tile layers as **colour blocks keyed by the tileset's
  own passability flags** (green passable / dark red blocked / yellow "always
  above characters" / blue autotile), a hero rectangle, arrow-key movement
  blocked by real per-tile passability. This mirrors `mruby-rpg2k`'s own
  history — map exploration with a colour-block fallback came before real
  ChipSet rendering, which came before the event interpreter, which came
  before battle — and mirrors the in-game map debug viewer's own existing
  green/dark-red convention (`docs/TODO.md` below records what is not built
  yet: the event-command interpreter — meaning **no events run**, only
  passive map geometry — and real ChipSet-image tile rendering).

Detection (`src/main.cxx`'s `is_wolf_game`) keys on
`Data/BasicData/Game.dat`, the one file every unpacked project has across
every version from 2.2x through current. `GameKind::kWolf` is dispatched the
same way `kRpgVx`/`kRpgXp` are, with one difference: because the screen size
is discovered at runtime rather than a fixed per-maker constant, the native
and Emscripten boot paths create the display at the existing 320x240 default
and resize it *after* `WolfRPG#initialize` has read `Game.dat` (gated on
`--width`/`--height` not being given explicitly, matching how every other
override already takes precedence).

`scripts/wolf_testbed_check.rb` loads this exact `mrblib` source under CRuby
(the LCF-side pattern) and parses every `BasicData` file plus every `.mps`
under `MapData` in the fetched sample game — it currently reads all 4 sample
maps, 36 events and 27,356 event commands (the entire bundled "RPG Basic
System") with no unhandled bytes left over. `mruby-wolf/test/wolf_test.rb`
unit-tests the byte-level primitives (`Reader`, the LZ4 decoder against
hand-built literal/match/overlap/extended-length blocks, the XOR cipher's
self-inverse property, the bit-field decoders) the way `mruby-lcf/test`
covers `read_ber`/cp932 rather than whole synthetic files.

## Consequences

- A WOLF RPG Editor project can now be pointed at like any other supported
  maker and shows its starting map, walkable, with real tile-by-tile
  passability — geometry only, no events, no message system, no battle.
- The event-command decoder (`Wolf::Command`) already carries every command a
  real project's Common Events use (validated against the RPG Basic System
  above), so the next piece — an interpreter running those commands, the way
  `mruby-rpg2k`'s `Interpreter` runs LCF's — has its input data fully in
  hand; only the execution semantics remain to build. `docs/TODO.md` tracks
  this as the next milestone, ahead of ChipSet image rendering, since no menu,
  title, save or battle system exists in the engine's own C++/mruby code the
  way it does for RPG2000 — WOLF RPG Editor's "Basic System" *is* Common
  Events, so nothing shows on screen beyond bare geometry until they run.
- Packed releases (`Data.wolf`, DxLib-encrypted) and Pro-protected data are
  not readable yet. `WolfDec`/`UberWolf` document the per-version archive
  keys; adding an archive reader is a follow-up in the same shape as
  `RPGXP::RGSSAD`, not a new problem.
- Real ChipSet-image tile rendering (base chips read from the tileset's own
  PNG, autotile quarter-tile assembly from `Wolf::Map.autotile_slot`/
  `autotile_shape`) is left for a follow-up; the colour-block renderer is
  structured so swapping it in later touches only `WolfRPG::MapScene`.
