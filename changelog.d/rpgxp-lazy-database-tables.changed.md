- **RPGXP: database tables load lazily instead of all eleven eagerly at
  open.** `RPGXP::RGSSData#initialize` used to `Marshal.load` every
  `Data/*.rxdata` table (Actors, Classes, Skills, Items, Weapons, Armors,
  Enemies, Troops, States, Animations, Tilesets, CommonEvents) the instant
  the database opened, before the game had picked a scene. A session that
  never opens a battle never needs Troops/Enemies/Animations -- routinely
  the largest files in this group -- and a short session may never touch
  several of the others either. Each table now loads on first access to
  its reader instead, memoized the same way as before. RPGVX/VX Ace's
  equivalent loader is intentionally left eager: its boot-time
  `[RGSS2-DB]` summary log reads every table's cache slot directly (not
  through the lazy accessor) to report a census, so making it lazy there
  would either force every table to load anyway (no benefit) or silently
  degrade that log to reporting nothing. Verified against a real project
  fixture: `scripts/rpgxp_testbed_check.rb` and
  `scripts/rpgxp_script_host_check.rb`, both passing unchanged.
