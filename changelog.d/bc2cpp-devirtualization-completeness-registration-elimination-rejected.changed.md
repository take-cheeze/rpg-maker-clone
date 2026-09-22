- Investigated a second lever for eliminating bc2cpp `register.cxx` entries
  beyond docs/adr/0193's "zero call evidence" pruning: dropping a MONO
  method's registration once every real call site devirtualizes to a
  direct C++ call, since nothing would ever need a dynamic method-table
  lookup for it. **Rejected as unsound at this project's current, partial
  bc2cpp coverage**, with a concrete, verified counterexample — not a
  hypothetical: `LCF::EventCommand#code`/`#indent` are registered MONO
  methods real, permanently-interpreted callers
  (`Game::Interpreter#skip_to`/`#do_show_choices`) still call by name.
  Devirtualization is a per-call-site decision, never a name-wide
  guarantee, and interpreted bytecode (the majority of this project's Ruby)
  is never devirtualized at all — proving no runtime lookup will ever
  happen would require tracking no existing tooling has. See docs/adr/0198.
