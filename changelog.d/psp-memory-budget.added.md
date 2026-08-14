- **PSP memory-budget plan.** ADR 0010's PSP bring-up assumed the full mruby
  gem set "should fit" in the console's ~24 MB of RAM without the
  gem-trimming/streaming-asset work the Wio Terminal port needed. ADR 0047
  checks that assumption against the code paths the interpreter-linking slice
  will actually exercise before it lands: mruby 4.0's global allocator hook
  defaults to sharing LVGL's memory pool (as it already does on desktop), so
  the PSP's 4 MB `LV_MEM_SIZE` may need to cover the whole mruby object graph,
  not just LVGL widgets, unless a PSP-specific allocator exception is added;
  and `RPGXP::RGSSAD.open` reads an entire packed archive into one `String`
  kept alive for the database's whole lifetime, which can exceed the whole
  budget for a real XP/VX game even though it's not on the RPG2k bring-up's
  path — fixable with no code changes by shipping such a title pre-unpacked
  onto the Memory Stick (the loose-file loaders already shadow the archive)
  and excluding the packed `Game.rgssad`/`.rgss2a`/`.rgss3a` so it is never
  eagerly read. See `docs/adr/0047-psp-memory-budget.md`.
