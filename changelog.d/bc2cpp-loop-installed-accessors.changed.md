- **bc2cpp** registers the accessors a constant-driven `attr_*` loop installs
  (`OPTIONS.each_value { ... attr_reader id }`) by executing the loop on its literal
  container, so calls of those names devirtualize; optcarrot's executed by-name
  dispatches drop 22.9% (ADR 0304).
