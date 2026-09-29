- bc2cpp: added a shadow check (`tools/bc2cpp/fixnum_barrier_shadow.rb`,
  `scripts/bc2cpp_barrier_shadow_report.rb`) comparing the Fixnum proof's
  exception barriers with handler-edge derived ones; no differences on the
  shipped gems, barriers unchanged (ADR 0250 addendum).
