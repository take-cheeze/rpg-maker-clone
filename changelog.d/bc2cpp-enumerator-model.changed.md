- **bc2cpp** (ADR 0416): `Enumerator` is modelled from the program's own bytecode. `Kernel#to_enum` is proven the
  one `to_enum`/`enum_for` (exact body `Enumerator.new self, meth, *args, **kwd`, intact construction chain, stable
  `Enumerator` constant), so a `to_enum(:x)` on an Array, Hash, Range or String the exact-class flow proves in a
  compiled mruby core body builds the Enumerator in place instead of looking `to_enum` up by name: on the wio
  closed world 34 of the 65 by-name `to_enum` sends go (1,792 to 1,758 `bc2cpp_send`), each behind the usual
  class test and guard violation. A `select`/`reject` store on an ivar that every other store makes an Array is now
  an Array store too, so `Game::Battle#@queue` is a proven Array (class hints 285 to 286). A census found no blockless
  iterator result reaching a project receiver, so no Enumerator class bit and no `each_with_index.map` fusion were
  added. `BC2CPP_ENUMERATOR_MODEL=0` restores the previous output; checks
  `scripts/bc2cpp/enumerator_model_check.rb` and `scripts/bc2cpp/enumerator_model_mutation_check.rb`.
