- RPG Maker **XP** events can now show pictures: **Show Picture** (231), **Move
  Picture** (232), **Rotate Picture** (233), **Change Picture Tone** (234) and
  **Erase Picture** (235). A `Game::Picture` per slot mirrors RMXP's
  `Game_Picture` — its position, origin, zoom, opacity, blend type, tone and
  angle, with the same weighted-average easing that lands exactly on the target
  on a move's last frame — and the map scene mirrors the list into sprites in
  their own viewport, above the map and below the windows, as RMXP's
  `Spriteset_Map` layers `@viewport2`. Pictures survive a Transfer Player, as
  they do in RMXP. Pray for You opens on a picture cutscene and uses these 471
  times.
