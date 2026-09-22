- Compiled `GETCONST` of a class/module constant no longer re-resolves its
  lexical scope chain on every execution (one `mrb_const_get` per owner path
  segment plus one probe per scope, `bc2cpp_const_try`). A site is routed
  through a per-(scope, name) helper that caches the class/module it finds,
  only for names the whole program provably binds to one class for the life
  of the VM: exactly one `class`/`module` statement, never assigned with
  `Name = ...`, not defined by native or foreign sources, and no
  `const_set`/`remove_const`/`autoload` anywhere (`StableClassConstants`,
  `tools/bc2cpp/const_site_cache.rb`). Failed lookups and non-class values are
  never cached; the cache is keyed on the VM and dropped by each compiled
  gem's `gem_final`, independently of the symbol cache. callgrind on the
  desktop build's steady-state map-scene frame: 947k Ir/frame before any fix,
  438k with the symbol cache alone (interpreter: 437k), 304k with both --
  bc2cpp now executes fewer instructions per frame than the interpreter. New
  `scripts/bc2cpp_const_site_cache_check.rb`.
