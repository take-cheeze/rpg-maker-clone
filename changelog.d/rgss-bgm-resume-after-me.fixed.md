- **RGSS3 BGM resume after a Music Effect / `RPG::BGM#replay`**: a map's BGM
  interrupted by `Audio.me_play` now resumes where it left off once the effect
  ends, instead of always restarting from the beginning — matching real
  RGSS3. `RPG::BGM#replay` (used after loading a save mid-track) now resumes
  at its own stored `pos` too, since `Audio.bgm_play`'s `pos` argument
  actually seeks. `RPG::BGS`/`RPG::ME`/`RPG::SE` are unaffected — only BGM's
  backend can resume a position.
