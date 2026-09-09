- **Fixed a real `NameError: uninitialized constant LCF::Database`
  affecting every shipped target**, not just wio — ADR 109's `schema.rb` ->
  packed-blob swap dropped `schema.rb` from every mruby build's own
  `spec.rbfiles`, but the generated blob only ever carried `LCF::Schema`'s
  *data*, never the hand-written `LCF::File`/`Database`/`MapTree`/
  `MapUnit`/`SaveData` classes that used to live in the same file. Caught
  by actually running the real ctest suite (`exe_open`, the desktop binary
  against real Nepheshel game data) rather than trusting relink-only
  measurements. Fixed by splitting those classes into their own file,
  `mruby-lcf/mrblib/lcf_file.rb`, loaded everywhere `schema.rb` is.
- **Scoped the ADR 109 schema-blob swap to wio only** — running it under
  every target (including mrbtest's own "host" build) surfaced a second,
  narrower bug: 6 of `LCF::Schema`'s 27 top-level constants
  (`DATABASE`/`MAP_TREE`/`MAP_UNIT`/`SAVE_DATA`/`SAVE_MOVABLE`/
  `SAVE_PARTY_ACTOR`) went missing under mrbtest's full 27-gem load despite
  being assigned correctly moments earlier — 28 test crashes, none of them
  reachable from any real shipped target (single maker gem, confirmed via
  `exe_open`/`render_probe`/`audio_probe`/`error_dump`). Restricting the
  blob to wio (the only target ADR 109's own numbers ever justified it for,
  and the only one that never runs through `rake test` in the first place)
  fixes `mruby_test` (28 crashes → 0) without giving up any of wio's flash
  savings. See ADR 123.
