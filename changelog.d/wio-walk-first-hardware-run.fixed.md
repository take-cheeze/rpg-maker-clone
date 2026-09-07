- Fixed `wio_walk`'s tile colours: `TFT_eSPI::pushImage`'s bulk transfer path
  needs plain (unswapped) R5G6B5 packing plus a byte-swap, unlike the
  single-pixel `fillRect`/`fillCircle` calls the player marker and backdrop
  use, which need this panel's BGR field order but no byte-swap. Found and
  verified against a real Wio Terminal — the first time this port's firmware
  has actually run on the board rather than just compiling in CI — walking a
  real Nepheshel map read off the SD card. Also adds a `wio_sd_upload`
  PlatformIO environment and `scripts/wio_sd_upload.py`: a throwaway loader
  firmware that writes files to the board's SD card over USB-CDC serial, for
  dev machines with a board but no card reader.
