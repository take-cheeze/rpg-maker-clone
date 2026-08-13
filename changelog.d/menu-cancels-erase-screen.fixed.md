- **Opening the Menu (Save included) now auto-cancels an active Erase Screen
  black-out**, with no "Show Screen" involved — matching yado.tk: RPG_RT
  never restores the black-out once the menu has been opened and closed.
  `Scene::Menu#initialize` instantly clears `Game::Screen`'s fade level via
  an explicit zero-frame `#show`, leaving an already-visible screen
  untouched.
