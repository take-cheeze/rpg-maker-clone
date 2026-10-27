- **bc2cpp**: the compiled gems' generation runs with a larger initial Ruby heap and higher malloc limits
  (`RUBY_GC_*` defaults in `tools/bc2cpp/compiled_gems.rb`; a value set in the environment wins). GC ran about half
  as often (254 to 139 collections, 35 to 11 major) and the rpg2k generation took 138.3 s to 133.9 s, for ~45 MB more
  peak memory; the generated code is the same.
