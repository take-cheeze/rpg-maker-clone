bc2cpp: `Scene::Map#ids_touch?` gets `# bc2cpp: (Array, Hash)`, so its `any?` loop
inlines instead of building a block-fallback cfunc.

The generated C++ loses the `BLOCK_FALLBACK :any?` site and the
`mrb_proc_new_cfunc_with_env` + `mrb_funcall_with_block` pair behind it. The
inlined loop keeps the existing `mrb_array_p` raise tripwire, so a wrong class
claim raises instead of miscompiling, and `ids.empty?` / `dirty.key?` stay
dynamic sends.

Measured on the hot-only RPG2k object, same `-Os` flags and cross-gem
declaration headers: `.text` 414,615 -> 414,349 bytes (-266), total -278.
Block fallbacks 35 -> 34.
