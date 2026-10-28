- **bc2cpp closed build:** a build-time proof (`tools/bc2cpp/core_enumerator_free.rb`,
  `core_enumerator_types.rb`) that no Enumerator is ever made, from every send of an
  iterator that returns one without a block (`each`, `map`, `index`, `step`, `select`,
  `chunk`, ...) and the class facts of its receiver. When it holds, the 15 methods of
  mruby-enumerator's Fiber machinery (`Enumerator#each`, `Kernel#to_enum`, `Enumerable#zip`,
  ...) leave the method tables; today it fails closed on 6 engine sites in two places
  (`scripts/bc2cpp/core_enumerator_free_report.rb` lists them, with the rewrite each needs).
