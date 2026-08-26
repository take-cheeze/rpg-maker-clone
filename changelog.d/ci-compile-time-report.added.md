- **CI:** the native build job now enables GCC's `-ftime-report-details`
  compiler-phase timing by default and posts a "slowest files/phases this
  run" bottleneck-hint table to the job summary, next to the existing sccache
  stats. Reports nothing on a fully cache-hit run, since sccache then never
  invokes the compiler at all -- it only grows informative exactly when a run
  actually recompiles a lot (a cold cache, a submodule bump, a widely-included
  header change).
