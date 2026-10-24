- **bc2cpp**: the exact-class flow types `+ - * /` on proven numbers under the
  numeric flow's own gates (EXACT_ARITH, `BC2CPP_EXACT_ARITH=0`), so Integer
  slots no longer show up as dropped class pools; the pool-drop report names
  dropped optional and polymorphic argument pools by what their sites pass; and
  `Game::Troop#member` is renamed `build_member`, which lets the Enemy database
  argument and ten Enemy stat ivars be pooled.
