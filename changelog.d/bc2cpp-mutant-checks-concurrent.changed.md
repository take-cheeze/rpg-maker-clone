- **bc2cpp mutation checks run concurrently.** The frozen-tables, call-results,
  class-pools and tuple-return mutation checks now use `Bc2cppMutantPool` like the
  other bc2cpp mutation checks, so `BC2CPP_JOBS` mutants run at a time instead of
  back to back, and a mutant stops at the FAIL line it is expected to cause.
  Measured on the generated-code halves: `core-tables` 11m13s to 1m51s, and
  `call-results` 2m22s to 45s, `class-pools` 5m31s to 1m35s, `tuple-return` 36s
  to 12s. Output and results are unchanged (byte-identical to a
  `BC2CPP_JOBS=1` run).
