- **RPG Maker VX / VX Ace** projects are now recognised and their databases
  load. The new `mruby-rpgvx` gem declares the RGSS2 (VX) and RGSS3 (VX Ace)
  `RPG::*` schema — the feature system, `damage`/`effects` usables, per-map
  tilesets and region layer of Ace, and VX's `parameters` tables, areas and
  game-wide `System#passages` — so every `Data/*.rvdata` / `*.rvdata2` file
  loads straight through `Marshal.load`, and `RPGVX::RGSSData` exposes them as a
  database (edition-aware extension and table set, maps on demand, script bundle
  decoding). A packed release loads too: VX's `Game.rgss2a` and VX Ace's
  `Game.rgss3a` are read through the existing `RPGXP::RGSSAD`. `src/main.cxx`
  detects the edition **before** the XP branch (a VX project has a `Game.ini`
  too, so it used to be mis-detected as XP) and sizes the window to VX's native
  544×416. A project that ships its scripts can be driven by the RGSS script
  host (`RGSS_SCRIPT_HOST`), which now shares one per-frame Fiber driver with the
  XP runtime; without it the boot reports the pending built-in flow instead of
  opening a blank window. Covered by `mruby-rpgvx/test` and by the new
  `scripts/rpgvx_testbed_check.rb`, which — no open-source VX/VX Ace test bed
  being fetchable — builds a full project per edition, drives the loader over it
  loose and repacked into its real encrypted archive, and audits that every
  field in the data has an accessor in the schema (the check that matters when
  it is pointed at a real game). See
  [`docs/adr/0024-rpgvx-rgss2-rgss3-data-layer.md`](docs/adr/0024-rpgvx-rgss2-rgss3-data-layer.md).
