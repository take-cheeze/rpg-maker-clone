- **bc2cpp strict hints:** verified on the real RPG2000/2003 workloads through a test-only sealed
  desktop host (`RPGMAKER_BC2CPP_CLOSED_WORLD_HOST=1`, `scripts/bc2cpp/strict_hints_verify.bash`,
  `-DBC2CPP_HINT_VIOLATION_LOG`). The candidate-set families (`poly_small_n`, `poly_table`,
  `interface_table`) no longer force a site where a known class outside the set answers the name
  (10 violations on boot and battle), and a hot-only build reads the owner-class cache for
  direct-constructed listed owners instead of unset hand-wired accessors (ADR 0428).
