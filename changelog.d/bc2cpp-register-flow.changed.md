- **bc2cpp** removes dead register copies and constant loads and propagates
  plain register copies in ordinary compiled methods, using a liveness pass
  over the emitted instruction texts (ADR 0415). `BC2CPP_REGISTER_FLOW=0`
  restores the previous output byte for byte.
