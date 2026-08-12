- Split the nine Ruby-only checks (LCF, RPG XP data/script-host, RPG VX/VX
  Ace, MV/MZ test-bed data, RPG2k event soak/game-logic/testbed-logic) out of
  CI's `build` job into a new `ruby-checks` job. None of them ever touch the
  compiled engine binary, so unlike everything left in `build`'s `parallel:`
  group they no longer have to wait on `cmake`/`build` (the native compile) —
  they run alongside `build` instead of after it, and `build`'s own
  `parallel:` group has a few fewer steps competing for its worker slots.
