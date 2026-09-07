- **WOLF RPG Editor (ウディタ/Woditor)** `Sound`(140) now also plays and
  stops real BGM/BGS tracks selected directly from the system database
  (help/05systemtype.html's own documented "BGMリスト"/"BGSリスト" tables),
  via new `WolfRPG::MapScene#play_track`/`#stop_track` -- cross-confirmed
  end to end against the sample game's own real data: its end-credits
  event's own two `Sound` calls decode to a database entry whose own name
  is literally "スタッフロール" (staff roll, matching the surrounding
  script's intent exactly) and the manual's documented `-1` "(停止)" stop
  sentinel. A variable-named source, Filename-mode BGM/BGS, and any
  unrecognised argument count remain logged and skipped rather than
  guessed. See `docs/adr/0072-wolf-rpg-editor-bgm-bgs.md`.
