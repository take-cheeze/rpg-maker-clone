- **Maix Amigo I2C driver hang**: `framework-maixduino`'s `Wire.cpp` had no
  timeout on its I2C wait loops -- an address that couldn't cleanly NACK
  spun forever, and on real hardware this wedged the board solid badly
  enough that even a full CPU reset couldn't clear it (only cutting power
  to the board could). `app/maix/patch_wire_i2c_timeout.py` now patches a
  50ms timeout into those loops (with an I2C peripheral reset on expiry)
  before every `maix_rgss_boot`/`maix_game`/`maix_game_sd` build. Sipeed's
  separate I2C Gamepad module (case D-pad/A/B/X/Y/Select/Start, address
  `0x4A` on the same bus as touch) is what surfaced this: even with the
  timeout in place it never once acked a read, and polling it at any rate
  dragged touch's own I2C1 transactions into the same slowdown, so it
  stays unwired (`maix_input.cxx`'s `gamepad_scan` implements the wiki's
  protocol for a future attempt).
