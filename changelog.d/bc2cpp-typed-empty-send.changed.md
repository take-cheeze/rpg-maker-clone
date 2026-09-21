- bc2cpp now tries exact receiver devirtualization before the built-in
  `empty?` intrinsic, so compiled Ruby overrides such as `Game::MoveRoute#empty?`
  can bypass dynamic dispatch while unknown receivers keep the existing
  container fast paths and Ruby fallback.
