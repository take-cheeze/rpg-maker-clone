- Three more compiled-send fast paths, each found from executed-funcall counts
  on the desktop `RPGMAKER_BC2CPP` build (RPG2k map scene):
  - A name whose only definition is an `attr_reader`/`attr_writer` (`code` and
    `indent` on `LCF::EventCommand`, ~85 funcalls per frame) is now an
    exact-class guarded chain with the funcall fallback instead of a bare
    `mrb_funcall` (a chain needed two candidates, and an accessor has no
    bytecode to be MONO). An embedded ivar's accessor calls the synthesized
    struct reader rather than `mrb_iv_get`, which would read nil.
  - The tail of an untyped `x[i]` goes through the same chain, so
    `Game::Variables#[]` is a direct call.
  - `a << b` on two immediate Integers uses `mrb_num_shift`, the kernel
    `Integer#<<` itself calls; overflow and `MRB_INT_MIN` keep the ordinary
    dispatch, so no bigint is produced from C on 32-bit `mrb_int` builds.
  New `scripts/bc2cpp_runtime_devirt_check.rb` covers all three, comparing the
  shift against `Integer#<<` on a real mruby core over 252 value/count pairs.
