- **bc2cpp**: the closed build leaves 22 more compiled `initialize` entries out of the method table. A construction
  site now counts as direct when each emitted copy calls the class's compiled `initialize` without a lookup: a
  construct in a block, a guarded construct whose miss is an error, a keyword-declaring initializer called without
  keywords, and an engine class built from another gem. The closed host table goes from 786 to 764 entries.
