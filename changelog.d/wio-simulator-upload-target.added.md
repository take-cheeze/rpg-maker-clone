- **`pio run -e wio_sim -t upload` boots the Wio Terminal bring-up firmware
  in the Renode emulator instead of flashing a board.** A new `[env:wio_sim]`
  in `platformio.ini` extends `env:wio` and points `upload_command` at
  `scripts/wio_renode_boot.bash`, so the familiar build-and-upload gesture
  works with no Wio Terminal attached (still needs a Renode built by
  `scripts/wio_renode_build.bash`); `upload_protocol = custom` drops the
  `sam-ba` path's upload-port autodetection, which otherwise fails before the
  command ever runs. See `docs/adr/0151`.
