- **The schema's edition-dependent defaults are no longer lambdas.** The six
  `default: -> { LCF.level_max }` / `LCF.exp_default` values were made by
  `schema.rb`'s class body, so they ran as bytecode: every read of an absent
  field entered the VM twice. They are now the Symbols `:level_max` and
  `:exp_default`, which `LCF.to_rb` resolves through `LCF.edition_default`, a
  compiled module function. A callable default still works, the wio schema blob
  and the type oracle's schema dump are unchanged, and `edition_default_check.rb`
  runs the reader interpreted and compiled. See `docs/bc2cpp-vm-entries.md`.
