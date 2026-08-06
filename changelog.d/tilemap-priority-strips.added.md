- **A roof now sorts against the character standing under it.** RMXP's per-tile
  priority put every priority tile above *every* character, so you always walked
  in front of tree crowns and rooftops. Priority tiles are now drawn into
  per-bucket canvas strips keyed on `ty + prio` — the same scale RMXP's own
  `Game_Character#screen_z` puts characters on — so a character one row lower
  sorts in front of a roof and one row higher sorts behind it. Strips are five
  tile rows tall (a bucket can be reached from five different rows), lazily
  allocated, and pooled by `bucket % 24` so a tall map cannot accumulate them.
  See ADR 0022.
