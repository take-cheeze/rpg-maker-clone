- **bc2cpp**: the closed build's unregistration proof reads core and external-gem Ruby as bytecode instead of
  text. A send there keeps a name registered only if its receiver may be an RPG2000/2003 object, and the
  workflows under `.github/` are no longer scanned for the closed list. The mrblib of the core gems compiled as
  program (array-ext, enum-ext, struct, enumerator, ...), which no scan read before, is now read too. The list grows from 1565 to 1587 names.
