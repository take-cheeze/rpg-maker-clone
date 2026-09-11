- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers
  `RGSS::Plane` in `mruby-rgss-compiled` -- its second owner, alongside
  the already-shipped `RGSS::Sprite`. All 6 of Plane's own real
  bytecode-defined methods compile clean: `#opacity`, `#zoom_x`,
  `#zoom_y`, `#blend_type`, `#tone`, and `#color`, each answering an RGSS
  default for an ivar only Plane's native `#initialize` (`src/lib.cxx`)
  ever sets, the exact same shape as Sprite's own identically-named
  methods -- no new opcode work was needed, including for `#tone`'s/
  `#color`'s own `@tone ||= Tone.new(...)`/`@color ||= Color.new(...)`
  (`||=` lowers to a plain GETIV/JMPIF-guarded-GETCONST+SEND+SETIV
  sequence, not a dedicated opcode). `attr_reader :bitmap, :ox, :oy, :z,
  :viewport` stays native/uncompiled, as always.

  Checked directly against the real embedding diagnostic, not assumed:
  `RGSS::Plane` gets no RData embedding at all -- it has no `#initialize`
  of its own (native, invisible to this compiler), and
  `drop_unsafe_embeddings`'s own class-level gate requires a *compiling*
  `#initialize` with pure mandatory arity before embedding anything on a
  class, so nothing on this class was ever an embedding candidate.
