- `tools/bc2cpp/bc2cpp.rb` can now devirtualize a genuinely polymorphic
  (POLY, multiple real definitions) method name at one specific call
  site, when that call site's receiver is provably a *freshly
  constructed* instance of one exact, statically known class (`x =
  SomeClass.new(...); x.method`, traced backward through the same
  straight-line method body, including a namespaced `Module::Class.new`
  constant-path chain) -- without needing any class-inheritance/MRO
  modeling at all (`SomeClass.new` always allocates the literal class
  it's sent to, never a subclass). Emits a distinct `TYPED` comment,
  separate from `MONO`/`POLY`. Verified via a real toy case (compiled,
  linked, and run -- correct dispatch, byte-identical to plain CRuby) and
  both already-shipped compiled targets (byte-identical, zero
  regression). Run against the whole real closed world: zero real hits
  today -- the pattern this targets (construct locally, immediately call
  a name that's *also* genuinely POLY, all in one straight-line body)
  doesn't occur in this codebase's currently-compilable method bodies, so
  this is sound, tested infrastructure with no live payoff yet rather
  than a measured win. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.
