- **bc2cpp class-object arguments** (`BC2CPP_CLASS_OBJECT_ARGS=0` turns it off): a `klass.new(...)` whose receiver is
  a method parameter (or a block's captured one) now names the class constants every caller passes, so the typed save
  records' generic `table`/`rows` helpers no longer withdraw every two-argument constructor from the constructor
  pools. On the wio build 28 more `initialize` argument sets are pooled (16 to 44), 149 `bc2cpp_getidx` callers and
  5 `bc2cpp_slow_*` callers become direct and 122 guarded fallbacks become errors, with the shipped C++
  byte-identical when the switch is off. New `class-object-args` CI shard
  (`scripts/bc2cpp/class_object_args_check.rb`, 17 mutants). See `docs/adr/0416-bc2cpp-class-object-arguments.md`
  and `docs/bc2cpp-class-object-args.md`.
