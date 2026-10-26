- **bc2cpp**: monomorphic calls into embedded-object methods reuse exact receiver
  flow to remove redundant class guards and fallbacks. Unknown receivers retain
  guards, and nilable receivers retain their existing nil checks.
