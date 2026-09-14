- **M5Stack Core port (P1 HAL bring-up)**: a new `app/m5stack` PlatformIO/
  Arduino firmware target for the M5Stack Core (ESP32, 320x240 ILI9341, three
  A/B/C buttons) -- the unit the "FACES" kit's interchangeable bottoms attach
  to. `mruby-rgss/src/m5stack.cxx` stands up an LVGL display over the panel
  via TFT_eSPI and scans the three buttons into a bitmask, the same shape as
  the Wio Terminal's own P1 HAL slice; `pio run -e m5stack` builds it. No
  mruby interpreter or asset loading yet. See `app/m5stack/README.md`.
