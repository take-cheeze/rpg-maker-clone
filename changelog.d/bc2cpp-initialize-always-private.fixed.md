- `tools/bc2cpp/bc2cpp.rb` was registering `#initialize`/`#initialize_copy`/
  `#respond_to_missing?` at whatever visibility the source happens to have
  in effect around the `def`, when mruby's own interpreter
  (`mrb_define_method_raw`, `src/class.c`) forces all three private
  unconditionally, for every class, regardless of source -- confirmed both
  by reading that code path and empirically (a `Foo#initialize` with no
  `private` anywhere in sight still raises `private method 'initialize'
  called for Foo` when called from outside). Never live in either
  already-shipped compiled target, since neither the registry mismatch
  nor a compiled `#initialize` call site had come up yet, but a real,
  observable behavior gap (a private method silently made externally
  callable) waiting for the next one. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.
