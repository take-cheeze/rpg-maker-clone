- **bc2cpp**: a constant whose definition may not run (`X = 1 if c`) is no
  longer folded to its value, so a read raises NameError as the interpreter
  does; a body that reopens one class path twice compiles.
