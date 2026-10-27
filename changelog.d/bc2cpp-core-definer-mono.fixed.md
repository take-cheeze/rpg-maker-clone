- **bc2cpp no longer binds a core method name to a program-only definition.**
  A program that defined `map` (or `collect`, `reject`, `each_with_index`,
  `sort_by`, `Hash#each_pair`, ...) only on an Array/Hash subclass made the
  name MONO. Every plain `a.map { }` then called the subclass body. Core
  definitions kept out of the registry, core aliases and Ruby that the run does
  not compile now keep such a name POLY (`docs/bc2cpp-core-definers.md`,
  `scripts/bc2cpp/core_definer_mono_check.rb`).
