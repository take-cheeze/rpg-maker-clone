- bc2cpp: a bare `new` in a class method that a subclass inherits now builds
  the subclass. The compiled code allocated the defining class unguarded, so
  `Kid.make` with `make` defined on `Base` returned a `Base` (ADR 0468).
