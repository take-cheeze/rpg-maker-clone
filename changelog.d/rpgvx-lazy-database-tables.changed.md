- **RPGVX/VX Ace: database tables load lazily instead of all eleven eagerly
  at open, closing the gap #1367 left for XP's own loader.** `RPGVX::RGSSData`
  used to `Marshal.load` every `Data/*.rvdata(2)` table unconditionally the
  instant the database opened -- Troops/Enemies/Animations (often the
  largest files in a real project) go untouched by any session that never
  opens a battle. This was left eager in #1367 because the boot-time
  `[RGSS2-DB]` summary log read each table's cache slot directly to report
  an exact record count, which would have either forced every table to load
  anyway or silently degraded the log to reporting nothing. Now unblocked:
  `#summary` reports a not-yet-loaded table's on-disk byte size instead of
  a record count (a loose file's own size, or the packed archive entry's
  already-parsed header size via `RPGXP::RGSSAD#entry_size`, a new small
  accessor -- neither needs a read, decrypt, or `Marshal.load`), and a
  table actually touched later still gets an exact count once it's cached.
  Verified against `scripts/rpgvx_testbed_check.rb`'s generated VX and VX
  Ace projects (both loose and packed), including the archive-entry-size
  path.
