- **Show Text keeps its window open for a Show Choices / Input Number that
  follows directly.** `Scene::Map` used to close the message window
  unconditionally once its text finished revealing, then build a brand-new
  window (or, for Input Number, an unrelated small centred widget) for the
  very next command — so a block like "How many potions?" followed by an
  Input Number, or a message followed immediately by a yes/no Show Choices,
  flickered the window shut and reopened it empty instead of appending the
  choices or digit entry below the text already shown, as RPG_RT does.
  `Game::Interpreter#do_show_message` now peeks at the next command (same
  indent, nothing in between); when it is Show Choices or Input Number, the
  scene keeps the same window and appends the choice list or digit cells
  below the existing text instead of closing and rebuilding it. The window
  still closes normally when nothing follows, or once the choice/number is
  confirmed.
