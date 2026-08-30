- **The field menu's Save command no longer shows a hardcoded English "You
  cannot save right now." message when Change Save Access has turned saving
  off.** Ported from a reference implementation, not independently
  confirmed against genuine RPG_RT under wine: a disabled Save command
  plays the buzzer SE and shows no message
  at all -- the menu simply stays put. `Scene::Menu`'s Save branch now
  matches: it pushes the save picker only when access is on, with no
  message otherwise.
