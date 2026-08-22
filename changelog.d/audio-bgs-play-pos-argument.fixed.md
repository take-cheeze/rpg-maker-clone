- Fixed `Audio.bgs_play` rejecting RGSS3's 4th (`pos`) argument, the same gap
  already fixed for `Audio.bgm_play`. Real stock `RPG::BGS#play` passes `pos`
  the same way `RPG::BGM#play` does, even though BGS has no seekable backend
  to resume it with; `Audio.bgs_play` now accepts and ignores a nonzero
  `pos` (warning once) instead of raising `ArgumentError`.
