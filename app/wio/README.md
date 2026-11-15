# Wio Terminal firmware

The Wio Terminal (Seeed, ATSAMD51) runs the **closed-world** RPG2k/2003 engine:
the Ruby is compiled by bc2cpp into C++ and linked into a VM-free libmruby, with
mruby-rgss's LVGL display and input HAL under it. There is no interpreted Wio
build, and no demo firmware.

## Building

The `wio` environment links a libmruby and uni-algo built outside
`platformio.ini`:

```sh
RPGMAKER_BC2CPP=1 MRUBY_TARGET=wio \
  RGSS_WIO_ARDUINO_INCLUDES=<colon-separated PlatformIO framework -I dirs> \
  rake                                          # libmruby.a (closed world)
# uni-algo: a standalone arm-none-eabi cross-build of 3rd/uni-algo
WIO_MRUBY_BUILD_DIR=<that build>/wio \
WIO_UNIALGO_LIB_DIR=<uni-algo lib dir> \
  pio run -e wio
```

`MRUBY_TARGET=wio` without `RPGMAKER_BC2CPP=1` fails in `build_config.rb`.
`env:wio` is `app/wio/src/wio_rgss_boot_main.cxx`, which boots the compiled
engine.

## `wio_sd_upload`: no SD card reader

`pio run -e wio_sd_upload -t upload` flashes a throwaway loader that writes
files to the microSD card over the USB-CDC serial connection, for a dev machine
with no way to pull the card out and mount it. Drive it with
`scripts/wio/sd_upload.py`:

```sh
pio run -e wio_sd_upload -t upload
scripts/wio/sd_upload.py <local file>:<path on the card>
pio run -e wio -t upload        # reflash the game afterwards
```

See `app/wio/src/sd_upload_main.cxx` for the serial protocol.
