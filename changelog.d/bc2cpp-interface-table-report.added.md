- `BC2CPP_ITAB_REPORT` (`tools/bc2cpp/interface_table_report.rb`) and
  `scripts/bc2cpp_interface_table_report.rb`: a per-site census of why a bc2cpp
  guard chain's else arm still dispatches by name, whether the receiver's class
  set is proven, and what each interface-table cell would be. ADR 0315 records
  why Go-style interface tables and RBS-style annotations were measured and not
  built. The report changes no generated code.
