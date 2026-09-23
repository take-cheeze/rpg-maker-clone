- **The bc2cpp bytecode strip now removes a stripped name that ends a mixed
  `public`/`private` list.** `scripts/strip_wio_bc2cpp_stubs.rb` shrank such a
  statement only up to the last kept name. A stripped name after that stayed
  in the list, and loading mrblib raised `NameError` because the method was
  undefined. The full compile never produced that shape. A hot-only list that
  compiles `RPG2k::Scene::Map#try_open_debug_menu` does (ADR 0214). Today's
  builds produce byte-identical output.
