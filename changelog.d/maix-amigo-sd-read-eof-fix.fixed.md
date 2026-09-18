- **Maix Amigo SD-card game boot**: fixed a long-standing hang that only
  showed up with a real, data-heavy game (never with the tiny synthetic
  `data/maix-hello` test), so it went unnoticed for a long time.
  `framework-maixduino`'s `File::read(void*, uint32_t)` loops until it
  satisfies the exact requested length, treating anything short of that
  as needing another retry -- but the real (bounded) `SdFile::read()`
  underneath correctly returns `0` at genuine end of file, which isn't an
  error, so that loop just spins forever once a read lands exactly at
  EOF. `app/wio/src/maix_sd_syscalls.cxx`'s `_read()` now calls the
  sibling `uint16_t` overload instead, which talks to `SdFile::read()`
  directly and returns a true short count. Confirmed on real hardware:
  a real commercial RPG2k title now boots from the SD card all the way to
  its title screen.
