- **UI:** an inactive window's selection cursor now stays visible, frozen
  on whichever frame it was on, instead of vanishing entirely -- matching
  RPG_RT's own `Window::Draw`, which never checks whether a window is
  active when drawing its cursor highlight (only `Window::Update` gates
  whether the highlight keeps blinking). Previously switching a list
  inactive -- e.g. after picking an actor from the main menu -- blanked its
  highlighted row instead of leaving it visibly selected.
