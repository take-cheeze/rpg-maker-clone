- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers
  `RGSS::Tilemap` in `mruby-rgss-compiled` -- its third owner, alongside
  the already-shipped `RGSS::Sprite` and `RGSS::Plane`. Its one real
  bytecode-defined method, `#autotiles` (`@autotiles ||= Array.new(7)`,
  RGSS's own fixed 7-slot autotile table), compiles clean -- no new
  opcode work was needed, including for resolving the bare core class
  `Array` through the same owner-scope-first constant lookup already
  shipped for Sprite's/Plane's own RGSS-namespaced `Tone`/`Color`
  lookups. `attr_reader :tileset, :map_data, :ox, :oy, :viewport,
  :priorities, :flags` and `attr_accessor :flash_data` all stay
  native/uncompiled, as always.

  Checked directly against the real embedding diagnostic, not assumed:
  `RGSS::Tilemap` gets no RData embedding at all -- it has no
  `#initialize` of its own (native, invisible to this compiler), and
  `drop_unsafe_embeddings`'s own class-level gate requires a *compiling*
  `#initialize` with pure mandatory arity before embedding anything on a
  class, so nothing on this class was ever an embedding candidate.
