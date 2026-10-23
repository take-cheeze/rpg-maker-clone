- **BC2CPP_TRACE_TYPES** return rows no longer mix in the values of other functions. The return wrapper stopped at
  the first brace imbalance it saw, and an `#ifdef`/`#else` pair that opens a brace in each arm left it open, so
  every later `return` was recorded under the earlier method. Instrumented builds only; the untraced output is
  unchanged. Covered by a new arm case in `scripts/bc2cpp/param_trace_return_check.rb`.
