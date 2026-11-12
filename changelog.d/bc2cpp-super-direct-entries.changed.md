- **bc2cpp closed build:** a parent method reached only by subclass `super` calls that compile to direct calls no
  longer stays in the method table; the closed host table falls from 741 to 735 entries (the six
  `RPG2k::Scene::Battle` methods the RPG2003 battle overrides call with `super`).
