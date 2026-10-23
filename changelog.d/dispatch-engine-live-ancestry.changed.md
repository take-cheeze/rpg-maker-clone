- **bc2cpp**: the engine-live check counts a send on `self` only when the
  enclosing method's class is an engine class or an ancestor of one. A core
  method's `dup` of its own instance cannot create an engine instance. The
  closed gate still fails on `Enumerator#each`'s `dup` of a splat array and of
  `@args`, which needs rest-parameter and instance-variable type facts.
