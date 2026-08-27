# rpg2k_walk — walk a real RPG2000/2003 map on iPod nano 7th gen

A from-scratch, non-mruby homebrew app that reads one map exported from a
real RPG Maker 2000/2003 project and lets you walk around it on a jailbroken
**iPod nano 7th generation**, using the [NanoApps](https://github.com/nfzerox/NanoApps)
homebrew SDK. See `docs/adr/0061-ipod-nano-7-homebrew-map-walk.md` for why
this is a separate minimal engine rather than the mruby/RGSS engine the rest
of this repo runs everywhere else, and for the full scope/limitations.

**Scope**: tile rendering (including autotiles, frozen at their first
animation frame) + grid movement + collision, for one static map. No events,
no interpreter, no battle, no menus — this walks a map, it does not play the
game.

## What you need

- A jailbroken iPod nano 7th generation with untethered code execution (e.g.
  [Pixosn0w](https://github.com/IAmDazen/Pixosn0w) / `ipod_sun`) and a
  [NanoApps](https://github.com/nfzerox/NanoApps) checkout set up per its own
  README (`./start`, on a Linux machine the iPod is connected to).
- A local checkout of this repo (`rpg-maker-clone`), to run the exporter and
  supply this app's source.
- Plain `ruby` (no mruby build needed — see below).

This repo does not vendor NanoApps, and there is no CI job for this port:
neither the toolchain conventions above nor the physical device are things
CI can exercise (the same reasoning PSP's best-effort `psp-smoke` job
documents, one step further — there is not even an emulator to boot this
under). Build and install are entirely manual, on your own hardware.

## 1. Export a map

From this repo:

```sh
ruby scripts/export_nano7_map.rb GAME_DIR MAP_ID OUT_DIR
```

For example, using the Nepheshel test-bed this repo's own test suite already
uses (`scripts/download-nepheshel.bash`):

```sh
ruby scripts/export_nano7_map.rb \
  data/Nepheshel206beta/Nepheshel206Nbeta 1 /tmp/rpg2k_walk_out
```

writes `map.bin` + `tiles.bin` to `OUT_DIR`. `scripts/export_nano7_map_check.rb`
round-trips the exporter's output against its own invariants (no mruby or
device needed) — run it after touching the exporter or this app's binary
format.

The exporter rejects (does not truncate) a map bigger than 128×128 tiles or
with more than 256 distinct on-screen tile ids — see the size-budget comment
in `rpg2k_walk.c`. Pick a smaller map if your project's start map is larger.

## 2. Build the app

NanoApps builds apps from inside its own checkout. Copy (not symlink — a
symlinked app directory resolves `../../sdk/hb_app.mk` against the physical
path, which lands outside NanoApps and fails) this directory into
`NanoApps/apps/`:

```sh
cp -r app/nano7/rpg2k_walk /path/to/NanoApps/apps/rpg2k_walk
cd /path/to/NanoApps
./start build rpg2k_walk
```

or, from inside `NanoApps/apps/rpg2k_walk` directly, plain `make` (needs
`arm-none-eabi-gcc` and Python 3 with `pyelftools`, which `./start` installs
for you the first time). The build's `.hbapp` should come out a few KB —
`.bss` (the map/tile static buffers) is not part of that packed image, only
code and constants are.

## 3. Install the map data and the app

With the iPod on its Home Screen (not "Connected" mode — see `hb_fs.c`'s
precondition), copy the exported files to the app's data directory and
install the app:

```sh
# from your NanoApps checkout, adjust the mount point ./start reports:
cp /tmp/rpg2k_walk_out/map.bin /tmp/rpg2k_walk_out/tiles.bin \
   /Volumes/IPOD/Apps/Data/RPG2kWalk/   # or wherever ./start mounted it
./start install rpg2k_walk
```

`./start`'s own menu can do the device-copy step for you too; see its
README. If the app opens to "no map.bin/tiles.bin", the data directory copy
didn't land — re-check the mount point and path
(`/Apps/Data/RPG2kWalk/map.bin` on the iPod's own filesystem).

## Controls

Touch anywhere and hold. The direction is whichever of up/down/left/right is
furthest from the screen's center — a whole-screen virtual joystick, the same
"zone" convention `apps/tetris`/`apps/paint` use. The player steps one tile
at a time while held, blocked by the map's real passability data.

## Known limitations

- One static map per export; no map tree, no teleport/transitions.
- Autotiles (water, terrain edges) render correctly but frozen at their
  first animation frame — no water/ground animation on-device.
- No events, message boxes, battle, or menus.
- Map size capped at 128×128 tiles / 256 distinct tile ids (see `rpg2k_walk.c`);
  a larger map is refused by the exporter rather than truncated.
