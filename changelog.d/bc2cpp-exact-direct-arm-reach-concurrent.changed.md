- **`core-exact-direct` and `block-arm-reach` run their mutants concurrently.**
  Both drove their mutants through a plain serial loop even though
  `Bc2cppMutantPool` existed for exactly that. They were the two slowest single
  commands in the bc2cpp check matrix — 1159s and 710s of their shards — so they
  now use the pool like a dozen other mutation checks. Measured locally:
  `core_exact_direct` 10m12s to 5m48s and `block_arm_reach` 6m51s to 4m27s, both
  with every mutant still killed and the verdicts byte-identical to a serial
  run. `core_exact_direct`'s unmutated control still runs first and alone, so a
  broken copy-and-run path is not blamed on a mutant.
