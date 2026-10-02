- **bc2cpp** call facts (ADR 0317): after `x.m` returned normally, a later `x.n` on the same value is judged against
  the declared classes that answer `m`, so 63 more by-name else arms of the engine gems become proven-dead
  `bc2cpp_nomethod`. `BC2CPP_CALL_FACTS=0` restores the earlier output. The ADR also measures provable errors as build
  errors (0 engine hits, not built); `BC2CPP_REFINE_REPORT` and `BC2CPP_PROVABLE_ERROR_REPORT` are the reports.
