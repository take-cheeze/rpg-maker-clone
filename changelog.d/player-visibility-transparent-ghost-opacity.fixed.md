- **Map:** Set Transparent Flag's parameter polarity was fixed to match
  RPG_RT (0 hides the player, non-zero shows it -- previously backwards).
  Separately, the leader actor graphic's own "Transparent" flag (Change Actor
  Graphic / the database Actor checkbox) now makes the player sprite
  translucent (opacity 159/255), matching RPG_RT's ghost effect, instead of
  hiding it outright -- the two were previously folded into a single hide.
