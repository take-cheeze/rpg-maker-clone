- **No-Float build:** `mruby-rpg2k` now builds with `MRB_NO_FLOAT` through
  `mruby-rpg2k/gen_rpg2k_nofloat.rb`, which replaces each `FLOAT-BEGIN/END` block with
  its no-Float form. The EXP curve uses 2**32 fixed point, so it can differ from the
  Float build by a point at most in about 0.3% of cases; the shake and tint steps and
  the save timestamp (1/1024 day) are also approximations there. The wave transition
  is off in that build.
