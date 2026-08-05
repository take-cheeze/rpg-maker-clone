# 17. RPG Maker XP: run the bundled RGSS scripts via an mruby eval host

Date: 2026-08-04

## Status

Accepted. The "opt-in for now" clause below is superseded by
[ADR 0029](0029-rgss-script-host-by-default.md): the host is the default boot
path and `RGSS_SCRIPT_HOST` is now the opt-out. Everything else here still
describes the host as built.

## Context

ADR 0010 brought RPG Maker XP up the way `mruby-rpg2k` brought up RPG2000:
**reimplement the default title/map/event flow directly against the database**
rather than executing the game's own scripts. That layer boots a stock project
to a walkable map with a working event interpreter, but it has a structural
ceiling — most non-trivial XP games customise their behaviour through the
`Data/Scripts.rxdata` scripts (custom menus, battle systems, community plugins
like the ubiquitous RGSS add-ons), and the reimplementation can never reproduce
that behaviour. ADR 0010 explicitly named "run the bundled RGSS scripts
unmodified" as the largest possible future direction, the RGSS analogue of the
MV decision (ADR 0004) to embed the game's real engine (a JavaScript runtime,
quickjs-ng, in `mruby-mvjs`).

How an XP project actually runs is simple in shape: `RGSS104E.dll` provides the
low-level primitives (`Bitmap`, `Sprite`, `Viewport`, `Window`, `Plane`,
`Tilemap`, `Table`/`Color`/`Tone`/`Rect`, `Graphics`, `Input`, `Audio`, the
`RPG::*` data structs, and the Kernel built-ins `load_data`/`save_data`), then
evaluates the ~90 Ruby sections in `Data/Scripts.rxdata` in order at the top
level. The final "Main" section runs the game loop (`$scene.main while $scene
!= nil`). Everything above the primitives — `Scene_*`, `Window_*`, `Game_*`,
`Interpreter`, `Sprite_*`, the battle system — is game-supplied Ruby.

The primitives already exist as `mruby-rgss`. The missing capability was a way
to *evaluate the scripts*, which needs three things this project did not have:
a runtime `eval`, a way to decompress the (zlib-deflated) script sections, and
the two Kernel data built-ins the scripts assume the engine supplies.

## Decision

Add an **RGSS script host**: run a project's bundled scripts unmodified through
mruby's own `eval`, against the native `mruby-rgss` class library.

- **`RGSS.zlib_inflate`** (native, `mruby-rgss/src/lib.cxx`) inflates a zlib
  stream by reusing stb_image's zlib decoder — already linked for PNG/XYZ
  loading — so no new dependency is pulled in. It decompresses each script
  section (and is generally useful for the other zlib payloads RGSS ships).
- **`RPGXP::RGSSData`** gains a public `read_object`/`save_object`
  (project-relative Marshal load/dump honouring the encrypted archive — the
  shape RGSS's `load_data`/`save_data` need) and a `scripts` accessor that
  decodes `Data/Scripts.rxdata` (a Marshal array of `[id, name, deflated]`) into
  an ordered `[name, source]` list.
- **`RPGXP::ScriptHost`** (`mruby-rpgxp/mrblib/script_host.rb`) installs the
  Kernel built-ins (`load_data`/`save_data` routed through the database, plus
  `$RGSS_SCRIPTS`) and `eval`s each section at the top level using its editor
  name as the "filename", so the game's own logic runs and "Main" drives the
  loop. Requires the core `mruby-eval` gem, now a `mruby-rpgxp` dependency.
- **Boot (`mruby-rpgxp/mrblib/lib.rb`)** runs the host when it is enabled and the
  project ships scripts; otherwise it uses the ADR 0010 built-in flow, which is
  also the fallback if the host fails to boot.

**The host is opt-in for now** (the `RGSS_SCRIPT_HOST` env var, read by
`ScriptHost.enabled?`),
defaulting off, for three reasons: it cannot be built or run in the current CI
sandbox (no SDL/mruby binary), the `mruby-rgss` class library is not yet
complete enough to satisfy every method the stock scripts call, and the scripts'
blocking `$scene.main while` loop needs Asyncify (or an equivalent) to cooperate
with the browser/emscripten frame loop. Keeping the built-in flow as the default
means the change lands the whole host without regressing the verified boot.

Because the host plumbing is written in the mruby/CRuby common subset, a new
host-side harness (`scripts/rpgxp_script_host_check.rb`, run in CI) loads the
exact sources under CRuby and drives them against the real
`data/OpenGame.exe/Testbed/XP` project: it decodes all 90 sections, installs and
round-trips the Kernel built-ins, and evaluates a load-safe logic subset
(`Game_*`, `Interpreter 1`–`7`), confirming genuine script source decompresses,
evaluates and defines its classes (`Interpreter#command_301`, `#command_121`, …)
at the top level.

## Consequences

- The pieces an eval-based engine needs — decompression, `eval`, the data
  built-ins, script ordering and top-level evaluation — now exist and are
  validated end to end against a real project's scripts. Turning the host on is
  a matter of completing the `mruby-rgss` class library the scripts call, and is
  no longer blocked on missing infrastructure.
- Running community/custom scripts (the whole point of the RGSS ecosystem)
  becomes reachable on the same path, exactly as embedding quickjs made MV's own
  scripts run.
- **Trade-offs / follow-up.** The host is not yet the default and is unverified
  on the native target until the SDL/mruby build can run in CI. Remaining work:
  fill in the `mruby-rgss` methods the stock scripts exercise — the precise gap,
  measured against the real test-bed scripts, is tracked in
  `docs/rpgxp-rgss-api-gap.md` (`Font`/`Graphics`/`Input`/`Audio` are already
  covered; the open pieces are `Sprite` extended properties and the empty
  `Window`/`Tilemap`/`Plane` widgets, plus `Kernel#sprintf`); resolve the
  blocking-main-loop/emscripten
  mismatch (Asyncify or a driver that pumps one `Scene#main` iteration per
  frame); and read graphics/audio out of the encrypted archive (still loose-file
  only). `mruby-eval` also enlarges every build that includes the RPG-maker gem
  set, including the constrained embedded targets. Once the library is complete
  enough to boot the test bed natively, the host becomes the default and the ADR
  0010 reimplementation stays as the fallback for projects that ship no scripts.
