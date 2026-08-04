- `scripts/mv_testbed_check.rb`: a host-runnable (CRuby, no JS engine)
  validator for the RPG Maker MV test-bed database, mirroring the existing
  `lcf_testbed_check.rb` / `rpgxp_testbed_check.rb`. It parses a project's
  `data/*.json` and asserts the boot-critical invariants — a positive
  `startMapId` whose `Map%03d.json` exists and whose `data` length equals
  `width*height*6`, a `tilesetId` that resolves to a tileset with 9 image names
  and 8192 passage flags, `partyMembers` that resolve to actors, and each
  actor's `classId` resolving to a class with an 8-row params table. Wired into
  CI as a **blocking** step ahead of the non-blocking native MV smokes, so a
  regression in the committed `data/mv-sample` (or a downloaded MV bed) fails
  the build instead of silently breaking the map/battle/message smokes.
