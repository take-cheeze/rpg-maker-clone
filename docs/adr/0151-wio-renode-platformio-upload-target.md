# 0151: A PlatformIO upload target that boots the Wio firmware under Renode

Date: 2026-09-13

## Status

Accepted.

## Context

ADR 94 builds a Renode platform that boots this repo's real Wio Terminal
firmware ELFs to their own `setup()`/`loop()` with no board attached, and
`scripts/wio_renode_boot.bash` is how it is driven. That path is still a
two-step, Renode-specific incantation: build the firmware with
`pio run -e wio`, then hand the ELF's path to the boot script with
`RENODE_BIN` pointing at a from-source Renode build. Flashing real hardware,
by contrast, is the one gesture a PlatformIO user already knows —
`pio run -e wio -t upload`.

The gap is ergonomic, not functional: nothing about the emulator changes, but
the "build this firmware and see it run" action is spelled two different ways
depending on whether a board is plugged in. The ask this ADR answers: make
the emulator reachable through the same `-t upload` target, without taking
over the real `sam-ba` upload path real hardware still needs.

Two PlatformIO mechanics decide the shape of the fix, both checked against
the installed platform source rather than assumed:

- `upload_command` is a project option that overwrites the platform's
  `UPLOADCMD` (`platformio/builder/main.py`), so an env can replace *what
  upload runs* without touching *how the firmware is built*.
- The atmelsam platform's real protocol is `sam-ba`, whose upload action list
  runs `BeforeUpload` → `AutodetectUploadPort` *before* the upload command
  (`platforms/atmelsam/builder/main.py`). With no board attached that step
  raises before anything emulator-related runs, so overriding
  `upload_command` alone is not enough. Its `custom` protocol instead maps to
  the upload command alone.

## Decision

Add `[env:wio_sim]` to `platformio.ini`: it `extends = env:wio` (one
definition of how the firmware is built, no duplicated flags or source
filters), sets `upload_protocol = custom`, and sets `upload_command` to
`scripts/wio_renode_boot.bash $BUILD_DIR/${PROGNAME}.elf`. So
`pio run -e wio_sim -t upload` builds the `wio` firmware and boots that
env's own ELF in the emulator — the same script, platform and fixed
virtual-time boot the manual invocation uses, now behind the standard upload
target. `$BUILD_DIR/${PROGNAME}.elf` is named explicitly because on this
platform `$SOURCES` is the `.bin` the `sam-ba` path uploads, not the ELF
Renode loads.

Renode stays out of the repo (ADR 94's existing decision): the env sets no
`RENODE_BIN`, so the boot script's own "install Renode or set RENODE_BIN"
error still tells a fresh machine what it is missing.

The real `env:wio` is untouched — `pio run -e wio -t upload` still flashes
hardware.

## Consequences

- **The emulator gets the same muscle memory as the board.** A contributor
  who already types `-t upload` gets a booted firmware by changing only the
  env name, with no separate script invocation and no device discovery.
- **One env, not a mechanism.** Only `wio` has a `wio_sim` twin today;
  `wio_walk` and `wio_sd_upload` still use `scripts/wio_renode_boot.bash`
  directly. Adding a twin for either is the same three lines, and this ADR
  does not claim otherwise — the value here was proving the wiring against
  the real atmelsam action list, which is the part that would be retyped.
- **`upload_protocol = custom` is a load-bearing detail, not decoration.**
  Removing it silently reintroduces the hardware-port autodetection that
  makes the sim path fail on a machine with no board; the comment in
  `platformio.ini` and `app/wio/renode/README.md` both say so.
- **No CI change.** CI's `wio-renode` job already drives the ELFs through
  `scripts/wio_renode_boot.bash` and keeps doing so; this ADR changes the
  local gesture, not the pipeline.
