- **Compare RPG2000 rendering against the genuine runtime.**
  `scripts/compare-nepheshel-wine.bash` boots the real `RPG_RT.exe` under wine
  and this engine on the same game, drives both headlessly with the same key
  script and writes per-step reference / ours / difference frames plus a pixel
  metric. The engine also gains `--rpg2k_new_game` (mirroring `--mv_new_game`),
  which selects New Game without input and logs `[RPG2k-MAP] map=… x=… y=…`, so
  CI can smoke-test the LCF map path against real Nepheshel data. See ADR 0021.
