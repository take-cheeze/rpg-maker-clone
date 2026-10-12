- bc2cpp reads RBS signature files (`sig/bc2cpp/**/*.rbs`, `BC2CPP_SIG_DIRS`) as parameter, return, ivar and element
  class hints, with the same effect as `# bc2cpp:` comments; the type check reports signatures that contradict the
  inference at the signature's own `file:line:col`. Unsupported RBS syntax is a located diagnostic (ADR 0413).
