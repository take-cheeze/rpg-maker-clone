- **bc2cpp**: the numeric slow paths, `===` and the checked-send helper are now one copy per link, not one per compiled
  gem. Their owner calls name the method by presym id and are dated by one program-wide owner epoch. `extern "C"`
  prototypes move with their callers into the shared headers. Wio FLASH -8.9 KB, static RAM -380 B.
  `BC2CPP_HELPER_PROGRAM_SITES=0`, `BC2CPP_CROSS_GEM_C_PROTOTYPE=0` and `BC2CPP_CROSS_GEM_CONDITIONAL_USINGS=0`
  turn the pieces off.
