- **CI now boots all three Wio Terminal firmwares under Renode
  (ADR 94 P5).** A new `wio-renode` job in `.github/workflows/build.yml`
  builds Renode from source (cached on the platform's peripheral sources),
  boots `wio`, `wio_walk` and `wio_sd_upload` and asserts each reaches its
  own `setup()` and `loop()`, re-runs the ILI9341 display peripheral's smoke
  test and checks its rendered pixels with ImageMagick, and smoke-tests the
  SD card image tooling — catching a regression in any of this platform's
  peripherals without needing the real board. The `wio` job itself now also
  builds `wio_sd_upload`, matching `wio` and `wio_walk`.
