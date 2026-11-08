- **The closed bc2cpp build leaves more mruby core methods out of its method
  tables.** The core reachability scan no longer counts the implicit-protocol
  list (`ALWAYS_DYNAMIC`), `MRB_OPSYM(div)` and cdump's operator rows as lookups
  of identifiers, a literal passed to the verified message formatters
  `mrb_int_overflow` and `mrb_sys_fail`, or the Symbol `Array#index`/`#rindex`
  hand to `to_enum` while no Enumerator is made. `scripts/bc2cpp/core_kept_report.rb`
  prints why each core ROM entry the build keeps stays.
