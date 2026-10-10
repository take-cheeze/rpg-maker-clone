- **Build tooling (bc2cpp):** a send inside an inlined block body (for example `@queue.each { |c| c.actor }`)
  now resolves the exact-class arm of a definer the guard chain cannot list, like a send outside a block: a
  private method called with an explicit receiver raises the NoMethodError the VM raises instead of going
  through a by-name call (27 sends), and a keyword-less call to a keyword method on an embedding class ends
  its guard in the closed world's proven fallback (7 sends). `BC2CPP_INLINED_UNLISTED=0` and
  `BC2CPP_KEYWORDLESS_FALLBACK=0` restore the old output. See ADR 0386.
