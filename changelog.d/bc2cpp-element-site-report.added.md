- **bc2cpp** gains `BC2CPP_ELEMENT_REPORT` and `scripts/bc2cpp_element_site_report.rb`, a census of the
  by-name call sites whose receiver is an element of a container and of the classes stored into container ivars.
  ADR 0312 uses it to record that element classes of mutable Arrays/Hashes are not worth building (28 of 15,349 engine
  sites even in the ceiling); the generated C++ is unchanged.
