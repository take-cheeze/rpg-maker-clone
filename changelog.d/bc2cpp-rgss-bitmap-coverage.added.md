- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers
  `RGSS::Bitmap` in `mruby-rgss-compiled` -- its fifth owner, alongside
  the already-shipped `RGSS::Sprite`/`RGSS::Plane`/`RGSS::Tilemap`/
  `RGSS::Window`. Only 2 of its own real bytecode-defined methods compile
  clean: `#font` (`@font ||= Font.new`, the same `||=` shape as Sprite's
  own `@tone ||=`/Window's own `@cursor_rect ||=`) and `#font=` (`@font =
  f`, a plain setter).

  Everything else on this larger, more varied class stays on the
  ordinary interpreter fallback: `#initialize` has one optional argument
  (the same non-mandatory-arity gap every other optional-argument
  `#initialize` in this codebase already hits); the private
  `#init_from_archive` hits an unsupported `.each`-with-block loop before
  it ever reaches its own trailing `rescue` clause (also unsupported);
  the nested `RGSS::Bitmap::LoadError#initialize`'s own `super(...)` call
  hits the same already-documented `super` gap every other
  `#initialize`-calling-`super` hits. `def self.failure_reason` -- a
  bare `def self.x` singleton method -- turns out to be un-compilable for
  a deeper reason than any of the above: this compiler's own registry
  fix for `def self.x` methods (needed so a same-named instance method
  elsewhere is correctly treated as polymorphic) registers such a method
  with no method body attached at all, by design, so it can never
  itself become a compile target regardless of what its own body does;
  documented in docs/adr/0139 as a first-time-confirmed distinction
  between "visible to the registry" and "eligible to compile".

  Checked directly against the real embedding diagnostic, not assumed:
  `RGSS::Bitmap` gets no RData embedding at all -- `#initialize` doesn't
  compile, and `drop_unsafe_embeddings`'s own class-level gate requires a
  *compiling* `#initialize` with pure mandatory arity before embedding
  anything on a class, so nothing on this class was ever an embedding
  candidate.
