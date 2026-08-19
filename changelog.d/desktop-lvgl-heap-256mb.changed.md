- **Desktop build** the LVGL memory pool (which backs *every* allocation on
  this build — mruby's whole VM heap included, not just graphics — see
  `src/main.cxx`'s `lvallocf`) grows from 64 MB to 256 MB. A large real game
  (games maker or not) with a rich enough database — hundreds of maps,
  enemies, skills, items — could exhaust 64 MB just loading its `Data/`
  tables, aborting with `NoMemoryError` before a single scene ran. Measured
  against a real ~60-hour freeware VX Ace release (468 maps, 930 skills, 610
  enemies, 635 troops): 64 MB and 128 MB both failed during database load,
  256 MB did not. The PSP and Wio builds keep their own much smaller,
  already-tuned pools (`app/psp/lv_conf.h`, `app/wio/lv_conf.h`) — this only
  raises the desktop ceiling, where headroom is cheap.
