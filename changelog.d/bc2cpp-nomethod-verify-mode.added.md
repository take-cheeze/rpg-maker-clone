- `BC2CPP_NOMETHOD_VERIFY=1` (build environment) defines the C++ macro of the
  same name so a dead `bc2cpp_nomethod` site aborts without dispatching, for
  running the psp/maix/wio smoke suites against the closed-world proofs. Off by
  default; see `docs/bc2cpp-nomethod-verify.md` and ADR 0275.
