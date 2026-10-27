- **bc2cpp**: the compiler's own guards now carry branch hints. The Integer tag
  tests of the arithmetic, ordering, bitwise and shift arms, and the class
  guards of TYPED / MONO_EMBED_GUARD / IVAR_ACCESSOR calls, are `mrb_likely`.
  The overflow tiers and `bc2cpp_ary_entry`'s bounds test are `mrb_unlikely`.
  A POLY_SMALL_N chain's last else is a GCC cold arm. User branches stay
  unhinted. On the optcarrot probe, 1800 frames run about 19% faster, with
  2.5% fewer instructions, 17% fewer conditional mispredicts and 32% fewer I1
  misses in callgrind. `BC2CPP_BRANCH_HINTS=0` restores the old output byte
  for byte. The probe's new `OPTCARROT_COMPILED_FLAGS` builds a PGO
  reference. See `docs/bc2cpp-branch-hints.md`; check
  `scripts/bc2cpp/branch_hints_check.rb`.
