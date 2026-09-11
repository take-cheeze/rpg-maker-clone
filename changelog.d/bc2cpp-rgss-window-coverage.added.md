- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers
  `RGSS::Window` in `mruby-rgss-compiled` -- its third owner, alongside
  the already-shipped `RGSS::Sprite`/`RGSS::Plane`. 12 of Window's own
  real bytecode-defined methods compile clean: `#opacity`,
  `#back_opacity`, `#active`, `#pause`, `#stretch`, `#openness`
  (nil-guarded-default readers, the same shape Sprite/Plane already
  use), `#cursor_rect` (`@cursor_rect ||= Rect.new(0, 0, 0, 0)`, the same
  `||=` shape as Sprite's own `@tone ||=`/`@color ||=`), `#padding` and
  `#arrows_visible` (nil-guarded-default again), and `#open?`/`#close?`/
  `#padding_bottom` -- each a same-class self-call to another compiled
  Window reader (`#openness`, `#openness`, `#padding` respectively),
  MONO-devirtualized into a direct C++ call rather than `mrb_funcall`,
  the same mechanism already proven for every other same-owner self-call
  in this whole program. `attr_reader :contents, :windowskin, :x, :y,
  :width, :height, :ox, :oy, :z, :viewport, :contents_opacity` stays
  native/uncompiled, as always.

  `#initialize` does not compile -- it has 4 optional arguments (`x =
  nil, y = nil, width = nil, height = nil`), the same
  non-mandatory-arity gap every other optional-argument `#initialize` in
  this codebase already hits, so it stays on the ordinary interpreter
  fallback. Its own `alias_method :_rgss1_initialize, :initialize` line
  is a new shape for this compiler: `alias_method` lowers to a plain
  self-implicit method call with no dedicated bytecode operand naming
  the new method, so the aliased name never enters this compiler's
  method registry under any owner at all -- confirmed harmless here
  since `#initialize`'s own non-mandatory-arity gap already drops that
  method (and its `_rgss1_initialize` call) before the registry gap could
  ever matter, but documented in docs/adr/0139 as a real, general missed
  optimization (never a correctness risk, per this prototype's own
  under-compile-is-safe rule) for any future `alias_method`-defined name
  with a live, otherwise-compiling call site.

  Checked directly against the real embedding diagnostic, not assumed:
  `RGSS::Window` gets no RData embedding at all -- `#initialize` doesn't
  compile, and `drop_unsafe_embeddings`'s own class-level gate requires a
  *compiling* `#initialize` with pure mandatory arity before embedding
  anything on a class, so nothing on this class was ever an embedding
  candidate.
