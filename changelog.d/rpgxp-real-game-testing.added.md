- The RPG Maker **XP** checks now cover a *released* game as well as the
  editor-shaped test bed: **Pray for You** (`scripts/download-prayforyou.bash`),
  which ships as `Game.ini` + `Game.rgssad` with nothing loose on disk — the
  shape most XP games are distributed in. `scripts/rpgxp_testbed_check.rb` and
  `scripts/rpgxp_script_host_check.rb` discover a packed project (not only a
  loose `Data/`), and the archive round-trip re-packs the game's *own* archived
  entries when there is no loose `Data/` to read. That widens the data check
  from 1 map / 2 event pages / 15 commands to **70 maps, 1109 event pages and
  15,812 event commands**, and the script host from 90 to 193 decoded script
  sections. `scripts/rpgxp_boot_check.bash` boots both games by default and CI
  downloads and checks both.
