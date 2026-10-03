- **bc2cpp** `BC2CPP_DEAD_ARM_REPORT=FILE` reports every `bc2cpp_nomethod` / `bc2cpp_nil_receiver` arm of the closed world
  with its send shape, method reachability, guards and receiver origin (`scripts/bc2cpp_dead_arm_report.rb`,
  `scripts/bc2cpp_dead_arm_report_check.rb`, ADR 0330). A measurement only: no generated code changes, and no reachable
  arm was a latent bug.
