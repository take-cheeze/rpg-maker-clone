- **bc2cpp**: a method that the compiled code also looks up by name (for
  example a keyword call to a method made public in another class body) is
  no longer left out of the method tables. The verify build aborted on it.
