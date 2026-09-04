- `scripts/download-monodori.bash` — the first fetchable real-world **RPG
  Maker VX** test bed ("Monochrome Dreamer" / モノクローム・ドリーマー, a
  freeware release on fgamearchives). `rpgvx_testbed_check.rb`'s own comment
  used to say VX/VX Ace had no such bed because the editors and RTPs are
  commercial; this one ships entirely packed into `Game.rgss2a` with no loose
  `Data\` directory, so it needed `discover_games` and `check_archive` taught
  the same "read the Data entries back out of the archive itself" fallback
  `rpgxp_testbed_check.rb` already had for a packed XP release — VX's own
  discovery only knew to glob for a loose `Data/System.rvdata`. Wired into CI
  alongside the existing RPG2k/XP downloads.
  Checking a real 171-map project (versus the hand-built VX/VX Ace samples,
  6 maps between them) also found two invariants a real game breaks:
  `System#party_members` can legitimately ship empty (this game builds its
  starting party through event commands instead of the database's initial
  roster) and `Data\Areas.rvdata` can be a Marshal-dumped empty `Hash` rather
  than the usual `Array` when a game never uses the Areas feature — both
  checks now accept the shape a real release actually uses. It also turned up
  a stray `_` instance variable on `RPG::System` neither the VX nor the XP
  schema declared an accessor for, now added as an opaque field so a real
  game's database round-trips exactly.
