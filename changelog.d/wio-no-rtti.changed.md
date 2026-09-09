- **Wio Terminal: disabled RTTI (`-fno-rtti`)**, the follow-up ADR 120
  flagged but didn't pursue. `mruby-rgss/src/lib.cxx`'s
  `DataType<T>::data_type` was the one real `typeid` use in the whole gem
  set (confirmed by grep) — replaced with a plain `static constexpr const
  char* kTypeName` each wrapped type (`Rect`/`Color`/`Tone`/`Table`/
  `Bitmap`) now supplies itself, which also reads better everywhere
  (`typeid(T).name()` returns an implementation-mangled name; every target
  now gets the same plain `"Rect"`/etc.). Real relink: 604 bytes of flash
  recovered on wio, no RAM cost. See ADR 122.
