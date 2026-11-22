- **bc2cpp: constant Hash/Array literals in class bodies are built from flash
  tables even when a `def` follows them**, as are Array keys and proven Integer
  constants. The Wio Terminal image is about 6.5 KB smaller. `BC2CPP_LITERAL_WALK=0`,
  `BC2CPP_LITERAL_ARRAY_KEYS=0` and `BC2CPP_LITERAL_CONST_INTS=0` turn the parts off.
