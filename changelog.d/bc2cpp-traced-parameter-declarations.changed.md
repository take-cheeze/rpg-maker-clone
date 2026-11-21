- The closed bc2cpp build declares 38 engine methods' parameters with the
  class every call passed in the host sweep (`T?` where the method tests for
  nil). The declarations are checked on entry, and they remove 42 owner
  calls (1318 -> 1276).
