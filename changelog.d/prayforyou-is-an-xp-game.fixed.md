- Corrected the engine `scripts/download-prayforyou.bash` fetches: "Pray for
  You" is an RPG Maker **XP** game, not an RPG2000 one. Its `Game.ini` reads
  `Library=RGSS103J.dll` / `Scripts=Data\Scripts.rxdata`, and the archive ships
  `RGSS103J.dll`, `Game.exe` and a 14.8 MB packed `Game.rgssad` with no
  `RPG_RT.ldb` / `.lmu` / `.lmt` anywhere. `run-rpg2k-rpgrt-wine.bash` had
  listed it alongside Nepheshel as a classic `RPG_RT.exe` game, which it could
  never have been. Both comments now say what it actually is — and it is a
  genuinely useful test-bed for the **encrypted-archive** path, being a packed
  release with no loose `Data/` directory: `RPGXP::RGSSAD.open` reads it
  cleanly, 222 entries, with `Data\Scripts.rxdata` decrypting to 212792 bytes
  that start with Marshal's 4 8 magic.
