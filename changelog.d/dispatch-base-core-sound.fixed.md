- **bc2cpp**: the base static dispatch unregistration list (every non-closed
  target) is regenerated with the canonical core gems analysed. The old 540-name
  list was built with core Ruby invisible, so it could unregister methods core
  code reaches. The sound list is 3 names. Hand-written registrations still
  register every name, so no build output changes yet.
