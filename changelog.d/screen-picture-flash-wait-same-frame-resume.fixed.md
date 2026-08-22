- **Events:** a waited-for Tint Screen, Flash Screen, Move Picture, or Flash
  Sprite command now resumes the very next command the same real frame the
  effect settles, matching RPG_RT -- previously it always cost one further
  frame before the following command ran, for both the foreground event and
  a Parallel Process's own interpreter.
