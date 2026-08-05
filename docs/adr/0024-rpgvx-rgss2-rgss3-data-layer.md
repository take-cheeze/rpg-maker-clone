# 24. RPG Maker VX / VX Ace data layer (RGSS2 / RGSS3)

Date: 2026-08-04

## Status

Accepted

## Context

The engine covers RPG Maker 2000/2003 (LCF), XP (RGSS1) and the JavaScript
makers (MV/MZ). The two makers in between — **VX** (RGSS2) and **VX Ace**
(RGSS3) — were only reachable by accident: `RPGXP::RGSSAD` already decrypts
their release archives (`Game.rgss2a` is XP's version-1 format; `Game.rgss3a` is
the version-3 one, ADR "rgss3a"), but nothing could read what is inside them,
and `src/main.cxx` dispatched **any** directory holding a `Game.ini` to the XP
runtime — so a VX project was mis-detected as XP and failed on the first
`Data/System.rxdata` that does not exist.

Structurally VX and VX Ace are XP: `Game.ini`, a `Data/` folder of Ruby
`Marshal` dumps, a bundled script bundle that *is* the game engine. Three things
differ:

- the data extension — `.rvdata` (VX) and `.rvdata2` (VX Ace);
- the record schema — RGSS2 reworked XP's records (icon *indices*, faces,
  vehicles, `terms`, the item/actor page conditions), and RGSS3 reworked them
  again around a **feature** system: most records derive from `RPG::BaseItem`
  and carry `features`, skills/items carry a `damage` formula plus an `effects`
  list instead of fixed recovery fields, and per-level stats moved from
  `RPG::Actor#parameters` onto `RPG::Class#params`. VX ships `Areas` and one
  game-wide tileset (`RPG::System#passages`); VX Ace dropped areas, added
  per-map `Tilesets` with a `flags` table, and gave maps a fourth data layer of
  region ids;
- the screen — 544x416 instead of XP's 640x480.

There is no fetchable test bed for either edition. Both editors and their RTPs
are commercial, and unlike XP (OpenGame) and MV (the MIT `rpgtkoolmv`
corescript) no open-source project ships a genuine `Data/*.rvdata(2)` tree, so
the schema cannot be validated against real editor output in CI the way
`lcf_testbed_check.rb` and `rpgxp_testbed_check.rb` validate theirs.

## Decision

Add a `mruby-rpgvx` gem that layers the VX/VX Ace data layer on the XP runtime,
mirroring how the XP layer was staged (ADR 0010).

- **Schema** (`mrblib/rgss2_data.rb`). Declare the RGSS2 and RGSS3 records as
  behaviour-free attribute holders, so every `Data/*.rvdata(2)` file loads
  straight through `Marshal.load`. Field names are transcribed from the VX and
  VX Ace "RPG module" references, cross-checked between two independent
  transcriptions of the same chapters (the `rpg-maker-rgss3` reference gem and
  the `rgss_db` tool, which agree field-for-field on RGSS3 and gave the RGSS2
  set), the way ADR 0002 sources the LCF schema from the analysis wiki rather
  than from guesses.
- **One `RPG::` namespace.** `Marshal` resolves a class by its absolute path
  from `Object`, so `RPG::Actor` in an `.rvdata2` stream and `RPG::Actor` in an
  `.rxdata` stream are necessarily the same class in a build that links both
  runtimes. The VX schema therefore *reopens* mruby-rpgxp's classes and adds its
  fields; a record only carries the ivars its own stream wrote, so the unused
  accessors read back nil. RGSS3's superclass chain (BaseItem → UsableItem /
  EquipItem → Skill / Item / Weapon / Armor) cannot be expressed with real
  superclasses for the same reason — a class's superclass cannot change when it
  is reopened — so the inherited fields live in `BaseItemFields` /
  `UsableItemFields` / `EquipItemFields` modules that both the concrete classes
  and the (documentation-only) abstract classes include.
- **Loader** (`mrblib/rgss_data.rb`). `RPGVX::RGSSData` is the XP loader's
  counterpart, parameterised by edition: the extension, the edition-specific
  tables (`Areas` vs `Tilesets`) and the archive name. Encrypted releases reuse
  `RPGXP::RGSSAD` unchanged.
- **Detection** (`mrblib/lib.rb`, `src/main.cxx`). A project is VX Ace when it
  has `Data/System.rvdata2` or `Game.rgss3a`, VX when it has
  `Data/System.rvdata` or `Game.rgss2a` — the archive counts on its own because
  a packed release ships no loose `Data/` at all, and it is the only way to tell
  a packed VX release from a packed VX Ace one. `main.cxx` checks this **before**
  the XP branch (which keys on `Game.ini`, which VX projects also have) and sizes
  the window to 544x416.
- **Booting.** A VX/VX Ace game's engine *is* its script bundle, so rather than
  reimplementing a title/map flow first (the RPG2000/XP staging), the boot shell
  runs the project's own scripts through the existing RGSS script host (ADR 0017;
  on by default since [ADR 0029](0029-rgss-script-host-by-default.md), with
  `RGSS_SCRIPT_HOST=0` as the opt-out), driven by the same per-frame Fiber as
  XP (ADR 0023 — its construction moved into `RPGXP::ScriptHost.build_driver` so
  both shells share one driver). Without the host — a project that ships no
  scripts, or that opt-out — the shell reports the pending runtime instead of
  opening a blank window, as the MZ shell does.
- **Validation** (`scripts/rpgvx_testbed_check.rb`). Since no real bed can be
  downloaded, the check *builds* a complete project per edition — every `Data/`
  table, a map with an event, a common event, a script bundle — and drives the
  loader over it loose on disk and then repacked into the edition's real
  encrypted archive (`Game.rgss2a` v1 / `Game.rgss3a` v3), asserting the
  cross-references and the structural differences between the editions (three
  vs four map layers, `System#passages` vs `Tileset#flags`, `Areas` vs
  `Tilesets`). It also runs a **schema audit**: every instance variable in the
  loaded data must have an accessor. That audit is trivially true for the
  generated bed and is the whole point when the script is pointed at a real
  game, which is how a user with a VX/VX Ace project validates the schema:
  `ruby scripts/rpgvx_testbed_check.rb path/to/Game`.

## Consequences

- A VX or VX Ace project — unpacked or shipped as a single encrypted archive —
  now loads: its whole database is readable through a typed schema, and it is
  routed to its own runtime at the right resolution instead of crashing the XP
  one.
- A packed VX Ace release can be run end to end by the script host (whatever the
  RGSS class library covers), because `read_object` resolves through the
  archive.
- The generated test bed proves the *path*, not the *names*. A field the
  transcription got wrong or missed would only surface against real editor
  output; the schema audit makes that failure loud the moment someone runs the
  check on a real game, and a downloadable bed remains the wanted follow-up.
- The three editions sharing one `RPG::` namespace means a class carries the
  union of XP/VX/VX Ace fields. That is harmless for data (streams only set what
  they wrote) but means the schema files, not the class definitions, are the
  place to look up which fields an edition actually has.
- Still to come, in order: reading graphics/audio out of the archive (shared
  with the XP gap), the built-in title/map flow for a project whose scripts are
  not run, and the RGSS2/RGSS3 halves of the `mruby-rgss` class library the
  bundled scripts call (`docs/rpgxp-rgss-api-gap.md` tracks the RGSS1 set).
