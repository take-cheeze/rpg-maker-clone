- **32-bit targets without bigint**: Control Variables products and sums, the
  encounter step table, the random-encounter roll, panorama autoscroll on a
  long-running map and the RPG2000 EXP curve no longer pass 32 bits, so they
  give the same results without `mruby-bigint` instead of raising.
