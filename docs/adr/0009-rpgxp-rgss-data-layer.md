# 9. RPG Maker XP support: an RGSS data layer over mruby-marshal

Date: 2026-08-03

## Status

Accepted

## Context

The runtime already boots two RPG Maker families to a walkable map: the
LCF-based makers (RPG Maker 2000/2003, via `mruby-lcf` + `mruby-rpg2k`) and,
in progress, the JavaScript makers (MV, via `mruby-mvjs`). The remaining
mainstream family is the **RGSS**-based one — **RPG Maker XP/VX/VXAce**. Its
runtime primitives (`Bitmap`, `Sprite`, `Viewport`, `Table`, `Color`, `Tone`,
`Input`, `Audio`, …) already exist as the native `mruby-rgss` gem — that gem is
the shared graphics layer the other makers render through — but the XP boot
class (`mruby-rpgxp`) was an empty stub. Nothing loaded an XP project.

An RPG Maker XP project differs from the RPG2000 (LCF) format in how its data is
stored:

| Family            | Data format                    | How it is read                     |
| ----------------- | ------------------------------ | ---------------------------------- |
| RPG Maker 2000/03 | LCF binary (`*.ldb/.lmu/.lmt`) | hand-parsed chunk stream (mruby-lcf) |
| **RPG Maker XP**  | **Ruby `Marshal` (`Data/*.rxdata`)** | **`Marshal.load` → `RPG::*` objects** |
| RPG Maker MV/MZ   | JSON (`data/*.json`)           | a real JS engine (mruby-mvjs)      |

The whole XP database — `System`, `Actors`, `Tilesets`, `MapInfos`,
`MapNNN`, … — is a Ruby `Marshal` (version 4.8) dump of the editor's `RPG::*`
objects plus the RGSS value types `Table`/`Color`/`Tone`. The bundled
`mruby-marshal` gem already reads that stream: it instantiates each object by
its class path (allocating and setting instance variables directly, calling no
`initialize`) and dispatches the value types through their `_load` class method,
which `Color`/`Tone`/`Table`/`Rect` already implement natively in
`mruby-rgss` (`src/lib.cxx`).

The game's *logic*, by contrast, ships as ~90 Ruby scripts inside
`Data/Scripts.rxdata` (each zlib-deflated). Running those unmodified — the
equivalent of the MV "embed the real engine" decision (ADR 0004) — would need a
Ruby `eval` of RGSS-era (1.8) source plus the full RGSS class library. That is a
large, separate milestone.

## Decision

Support RPG Maker XP the way `mruby-rpg2k` supports RPG2000: **reimplement the
default title/map flow directly against the database**, rather than executing
the game's bundled scripts. Concretely:

- **Data layer (`mruby-rpgxp/mrblib/rgss_data.rb`).** Because `mruby-marshal`
  does the actual reading, the "parser" is just a declaration of the `RPG::*`
  schema: one behaviour-free attribute-holder class per serialized editor type,
  mirroring the RPGXP RGSS data model 1:1. `RPGXP::RGSSData` wraps
  `Marshal.load` of each `Data/*.rxdata` file (arrays 1-based with a leading
  `nil`, `MapInfos` a Hash, maps loaded on demand), the role `LCF::Database`
  plays for the RPG2000 side.
- **Runtime (`lib.rb` + `game.rb` + `scene.rb`).** `RPGXP` reads `Game.ini`,
  builds the database and drives a scene stack: a `Scene::Title` (title graphic +
  the default New Game / Continue / Shutdown commands, drawn with an XP-styled
  `Panel` window) and a first walkable `Scene::Map` (three tile layers as
  placeholder colour blocks, the party leader drawn from its `Graphics/Characters`
  sheet, grid movement with tileset passability and a follow camera). This is the
  same staged path the RPG2000 runtime took (colour-block tiles first, real
  chipset blitting later).
- **Sources are the mruby/CRuby common subset**, so `scripts/rpgxp_testbed_check.rb`
  loads the exact schema under CRuby and validates it against a real downloaded
  project (`data/OpenGame.exe/Testbed/XP`), the way `scripts/lcf_testbed_check.rb`
  guards the LCF loaders. `src/main.cxx` sizes the window to XP's native
  640×480 when it detects an XP project and the size was not overridden.

Running `Data/Scripts.rxdata` is explicitly **out of scope** for this layer and
left as future work.

## Consequences

- An RPG Maker XP test bed now loads end to end: the full `Data/*.rxdata` set
  parses into typed objects and the engine boots to a title screen, with New
  Game entering a walkable map. XP joins RPG2000 and MV as a detected, bootable
  family (`src/main.cxx` already dispatched `Game.ini` to `RPGXP`).
- The schema is the single source of truth shared by the native runtime and the
  host-side test-bed check, so format surprises in real editor output surface in
  CI rather than at runtime.
- Because the value types (`Table`/`Color`/`Tone`/`Rect`) already round-trip
  through Marshal natively, no C++ was needed for the data layer; the only native
  change is the XP window sizing in `main.cxx`.
- **Trade-offs / follow-up.** Reimplementing the default flow means games that
  customize their behaviour through scripts (most non-trivial XP games) will not
  reproduce that behaviour until a script host lands. Real chipset/autotile
  rendering, the event-command interpreter, menus, saving in the real `.rxdata`
  save format, and battle are all still to come — the same backlog the RPG2000
  runtime is working through, now shared with XP. Running the bundled RGSS
  scripts unmodified (an `eval`-based engine host) remains a possible larger
  future direction, mirroring ADR 0004's choice for MV.
