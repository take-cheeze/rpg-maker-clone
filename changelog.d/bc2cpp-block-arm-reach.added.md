- **bc2cpp: the exact-class core block arms (ADR 0270) now reach blocks nested in
  inlined loop bodies and sends whose arm chain was built twice, and a proven
  arm with a yield-free block drops its dead dynamic else** (ADR 0310). In the
  wio closed world the engine's (`Game::*`, `RPG2k::*`) literal-block sends go
  from 277 to 307 direct and from 68 to 38 dynamic-only, and its
  `mrb_funcall_with_block` sites from 328 to 287. `BC2CPP_BLOCK_ARM_REACH=0`
  restores the earlier output. Covered by
  `scripts/bc2cpp_block_arm_reach_check.rb`.
