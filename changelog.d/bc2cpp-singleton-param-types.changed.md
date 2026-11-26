- The bc2cpp declarations now give the parameter classes of
  `Game::BattlePage.active?`, `Game::EventPage.active?`, `Game::LegacyLsd.apply`
  and `Game::CommonEvent.index`. Each class is checked once when the method is
  entered, so the compiled bodies drop 22 by-name fallbacks and the Wio
  firmware gets smaller.
