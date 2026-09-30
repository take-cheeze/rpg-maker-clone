- **Build:** the bc2cpp closed-world analysis now sees every form of an outside-Ruby
  `def` (`private def loop`, `protected def`, `module_function def`, a `def` after
  `;` or in a one-line class body, `private attr_reader`), not only a `def` at the
  start of a line, so a name defined that way is no longer believed undefined and
  its fallback is no longer dropped or turned into `bc2cpp_nomethod`.
