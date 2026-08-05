- RPG Maker XP events honour the rest of their page's graphic: its **opacity**,
  its **blend type** and its **character hue**. All three were decoded and then
  dropped, so a page that fades an event to a ghost, adds it to what is behind
  it, or recolours a shared character sheet drew as a plain opaque copy of the
  original. A move route's *Change Opacity* / *Change Blending* now reaches the
  sprite as well, and the party leader's own `character_hue` is applied to the
  player's graphic.
