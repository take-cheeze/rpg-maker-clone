- **bc2cpp** (CONST_SITE_CACHE): a class or module reopened at its own qualified path (`module LCF` in every mruby-lcf
  file, `module RPG2k` in every scene) counts as one binding, so its reads are cached per site instead of walking the
  lexical scope chain each time: uncached reads went from 1,734 to 968 sites in the rpg2k gem and from 69 to 39 in
  lcf. Covered by `scripts/bc2cpp/const_site_cache_check.rb`.
