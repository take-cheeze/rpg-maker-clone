- Each compiled gem's `mrbgem.rake` (`mruby-lcf-compiled`, `mruby-rgss-compiled`,
  `mruby-rpg2k-compiled`) now depends on every file under `tools/bc2cpp/*.rb`,
  not just `bc2cpp.rb`, when deciding whether its generated C++ is up to date.
  `bc2cpp.rb` `require_relative`s several sibling files (`symbol_cache.rb`,
  `const_site_cache.rb`, `native_expression_devirt.rb`, ...) that change its
  output just as much as `bc2cpp.rb` itself; editing only one of those never
  touched `bc2cpp.rb`'s own mtime, so an incremental build's Rake `file
  generated => [...]` rule silently kept a stale generated file. New
  `scripts/bc2cpp_mrbgem_deps_check.rb` guards against a future regression.
