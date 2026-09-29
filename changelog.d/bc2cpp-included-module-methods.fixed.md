- bc2cpp resolves typed method calls through statically proven included and
  prepended module lookup chains when constant identity, method visibility, and
  the selected target are known. Ambiguous mixins keep Ruby dispatch.
