- **bc2cpp closed world: precise outside-file touch analysis** — an outside
  Ruby or native file now makes a class opaque only when it can create,
  reopen, subclass or rebind it (`tools/bc2cpp/touch_scan.rb`, ADR 0253);
  merely mentioning a class, instantiating it, or natively defining a class the
  closed world also declares no longer does. Unclassifiable constructs keep the
  old spelled-constants rule. On the wio build `opaque_definer` kept sites drop
  from 301 to 2 (`RPG2k` and the nine natively defined `RGSS` classes), with
  76 newly reviewed dead fallbacks in `NOMETHOD_REVIEWED`.
