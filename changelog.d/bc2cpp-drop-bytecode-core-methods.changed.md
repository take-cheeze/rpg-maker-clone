- **bc2cpp closed build:** fewer methods of mruby's own Ruby stay bytecode in the
  method tables. `alias` chains and `alias_method` in core mrblib now compile
  (`Enumerable#filter`, `StringIO#isatty`), and a new proof
  (`tools/bc2cpp/core_private_ruby.rb`) leaves out the private Kernel IO helpers
  (`p`, `print`, `printf`, `putc`, `puts`, `gets`, `readline`, `readlines`,
  `open`, the backtick) and the interpreted core methods no name reaches
  (`Enumerable#chunk_while`, `Enumerator#with_object`, `Enumerator.produce`,
  `IO.popen`). NameError/NoMethodError `#initialize` are compiled.
