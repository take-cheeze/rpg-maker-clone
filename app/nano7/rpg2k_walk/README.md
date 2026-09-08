# rpg2k_walk — walk a real RPG2000/2003 map on iPod nano 7th gen

A from-scratch, non-mruby homebrew app that reads one map exported from a
real RPG Maker 2000/2003 project and lets you walk around it on a jailbroken
**iPod nano 7th generation**, using the [NanoApps](https://github.com/nfzerox/NanoApps)
homebrew SDK. See `docs/adr/0061-ipod-nano-7-homebrew-map-walk.md` for why
this is a separate minimal engine rather than the mruby/RGSS engine the rest
of this repo runs everywhere else, and for the full scope/limitations.

**Scope**: tile rendering (including autotiles, and the water/block-C tiles
animating on RPG2000's own clocks) + grid movement + collision + the
player's own CharSet sprite (the project's initial party leader, walking
RPG2000's own cycle) + map events drawn as static sprites (each one's own
initially-active CharSet page, never animated or interpreted), for one
static map. No event commands, no interpreter, no battle, no menus — this
walks a map, it does not play the game.

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

writes `map.bin` + `tiles.bin` to `OUT_DIR` (the format is described at the
top of the exporter; `tiles.bin` is a palette-indexed tile atlas, 256 bytes
per tile, whose colours live in `map.bin`'s own palette — see
`docs/adr/0092`). `--target nano7` is the default; `--target wio` sizes the
same export for the Wio Terminal's smaller buffers instead. `scripts/export_nano7_map_check.rb`
round-trips the exporter's output against its own invariants (no mruby or
device needed) — run it after touching the exporter or this app's binary
format.

The exporter rejects (does not truncate) a map bigger than 128×128 tiles or
with more than 255 distinct composited tiles — see the size-budget comment
in `rpg2k_walk.c`. Pick a smaller map if your project's start map is larger.

## 2. Build the app

NanoApps builds apps from inside its own checkout, and this app is two
directories: the NanoApps half here, and the engine it runs
(`app/shared/rpg2k_walk`, shared with the Wio Terminal walk firmware — see
`docs/adr/0091`). One script stages both:

```sh
scripts/stage_nano7_walk_app.bash /path/to/NanoApps
cd /path/to/NanoApps
./start build rpg2k_walk
```

It copies rather than symlinks, deliberately: a symlinked app directory
resolves `../../sdk/hb_app.mk` against the physical path, which lands outside
NanoApps and fails. Copying this directory alone is no longer enough — the
build stops at a missing `rpg2k_walk_core.c`.

or, from inside the staged `NanoApps/apps/rpg2k_walk` directly, plain `make`
(needs
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

## Trying it without a device

You don't need a jailbroken iPod or the NanoApps toolchain to see this app
actually walk a real map: `app/nano7/host` links this file (`rpg2k_walk.c`)
completely unmodified against a host implementation of the small
`hb_raw_surface`/`hb_sdk` API it calls, built as part of this repo's normal
CMake build (`nano7_walk_host`, wherever SDL2 already is). See
`docs/adr/0102-ipod-nano-7-host-emulator.md` for why this is a host-side API
harness rather than a full SoC emulator like the Wio Terminal's Renode
platform (`docs/adr/0094`).

```sh
ruby scripts/export_nano7_map.rb --target nano7 \
  data/Nepheshel206beta/Nepheshel206Nbeta 1 /tmp/rpg2k_walk_out
mkdir -p /tmp/nano7_host_root/Apps/Data/RPG2kWalk
cp /tmp/rpg2k_walk_out/*.bin /tmp/nano7_host_root/Apps/Data/RPG2kWalk/
./build/nano7_walk_host /tmp/nano7_host_root      # interactive window, mouse = touch
```

`nano7_walk_host DATA_ROOT --frames N --screenshot out.bmp` runs headless (no
display needed at all) for `N` simulated ticks and saves the final frame —
what `scripts/nano7_host_smoke.bash` / the `nano7_host_smoke` ctest use to
check a real map actually renders, on every build.

That host build runs natively on your machine's own CPU, so it has nothing
useful to say about how expensive a frame is on the real device. For that,
`app/nano7/qemu` cross-compiles this same file with the real
`arm-none-eabi-gcc -mcpu=cortex-a8` and boots it under `qemu-system-arm`'s
`cortex-a8` core on a real PL110 display controller — a genuine (if
approximate) ARM instruction stream and per-frame cycle count, not a
fabricated one. See `docs/adr/0103-ipod-nano-7-qemu-cortex-a8-emulation.md`.

```sh
sudo apt-get install -y gcc-arm-none-eabi qemu-system-arm
scripts/nano7_qemu_build.bash /tmp/rpg2k_walk_out/map.bin \
  /tmp/rpg2k_walk_out/tiles.bin /tmp/nano7_walk_qemu.elf
scripts/nano7_qemu_run.bash /tmp/nano7_walk_qemu.elf \
  /tmp/frame.ppm /tmp/uart.log
grep NANO7-QEMU /tmp/uart.log   # per-frame PMU cycle counts
```

## Controls

Touch anywhere and hold. The direction is whichever of up/down/left/right is
furthest from the screen's center — a whole-screen virtual joystick, the same
"zone" convention `apps/tetris`/`apps/paint` use. The player steps one tile
at a time while held, blocked by the map's real passability data.

## Known limitations

- One static map per export; no map tree, no teleport/transitions.
- A map's parallax background becomes **one backdrop colour** (its average),
  painted behind the map and through any pixel the chipset leaves
  transparent. Nepheshel's world map draws its whole sea that way, so the
  approximation is what makes it look like sea; a detailed panorama will
  read as a flat colour.
- Animation is the water autotiles, the block-C animated tiles and the
  hero's own walk cycle, on RPG2000's own clocks (`docs/adr/0094`,
  `docs/adr/0096`). Everything else an RPG2000 map animates — event
  commands, pictures, weather — needs the interpreter and is out of scope.
  `--no-animate` freezes every tile if an export needs the atlas slots back
  (the hero still walks; its cycle costs no atlas slots, being a fixed
  block of its own).
- The player is the project's *initial* party leader (`RPG_RT.ldb`'s own
  System/player rows), drawn only if that leader carries a CharSet — a
  project whose real hero graphic is a runtime Change Sprite Association
  or a title-screen event (Nepheshel's own default party is exactly this:
  a blank placeholder actor) falls back to nothing being drawn, same as
  before this feature existed. No live game state to ask instead.
- **Map events draw as static sprites, never as anything more.** Only an
  event whose page is the one a fresh save's own page-selection rules would
  pick, and only if that page's graphic is a CharSet frame rather than a
  chipset tile, exports at all (`docs/adr/0102`); one resting frame, in
  whatever draw order the genuine renderer's own below/same/above-the-hero
  layering already gives it. No event command ever runs — no message boxes,
  no self-switches, no teleport, no shop or battle an event might trigger.
- Map size capped at 128×128 tiles / 255 distinct composited tiles (see
  `rpg2k_walk.c`); a larger map is refused by the exporter rather than
  truncated. 255 is the format's own ceiling now that an atlas index is one
  byte — the largest real map in the test data needs 146.
