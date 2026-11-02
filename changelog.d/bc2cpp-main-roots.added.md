- Add an opt-in bc2cpp emission profile rooted at the native host's `main`,
  pruning unreachable name-invisible method bodies before C++ generation while
  retaining startup, callbacks and named-call roots.
