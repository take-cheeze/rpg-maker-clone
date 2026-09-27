- **bc2cpp** keeps embedded ivars in mruby's ivar table when a known subclass
  overrides `initialize`, preventing inherited compiled methods from reading
  an unallocated or incompatible RData layout.
