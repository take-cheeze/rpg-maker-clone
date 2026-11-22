- **bc2cpp** (COLD_COMPACT): compiled methods that the host sweep calls at most 100 times
  (`sig/bc2cpp/cold_methods.txt`, 2257 of 3190) run their arithmetic and compare instructions through one
  shared out-of-line helper call per site instead of the inline fast path. This saves 148,816 B of Wio flash
  (2,649,376 -> 2,500,560 B). Methods not on the list keep the inline code. Regenerate the list with
  `scripts/bc2cpp/cold_profile.bash`; `BC2CPP_COLD_COMPACT=0` restores the inline code everywhere.
