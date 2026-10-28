- **mruby-rgss**: `Array#sort` with a comparator now sorts a copy with mruby's C `sort!` directly instead of going
  through an alias of mruby's own `#sort`. That alias kept a bytecode body, so the compiled closed build entered
  the VM on every sort (the most frequent VM entry after boot), and its `sort!` dispatched back into the
  override and normalised the comparator twice. Results are unchanged.
