- **bc2cpp**: the closed world's static dispatch unregistration list is
  regenerated with the closed build's own core gems analysed. Core Ruby runs in
  the closed binary, and `Enumerator#each`'s `dup` on an unknown receiver can
  create an engine instance, so the earlier 1119-name list could unregister
  methods reachable by name. The list is now 24 names.
