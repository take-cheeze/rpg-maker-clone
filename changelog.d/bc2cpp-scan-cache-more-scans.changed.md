- Extend the bc2cpp native-source scan cache (ADR 0415) to `native_names`
  (nil-class operators, outside ivars, native method names, foreign method
  names), `StableClassConstants` (native class/module names, foreign reassigned
  names) and `IntegerConstants` (native-defined and foreign const names), so
  those scans are computed once per input set across generator processes.
