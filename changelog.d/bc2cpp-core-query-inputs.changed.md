- **bc2cpp** reduces check-phase allocation in core Ruby result queries by
  sharing immutable empty inputs and a static core receiver mask while retaining
  current flow reads, live proof guards and recursive exclusions.
