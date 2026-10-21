- **bc2cpp type check** now types more engine constants: `Color.new` constants written in several scene classes
  (`inferred:constructed`), and bit-operator constants over foreign literal definitions such as
  `StringIO::READWRITE` (`inferred:integer-class`). See `docs/bc2cpp-type-check.md`.
