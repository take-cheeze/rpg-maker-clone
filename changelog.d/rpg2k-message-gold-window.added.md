- A message containing `\$` now shows the party's gold in a small window
  alongside the text (RPG2000's money display), which closes together with the
  message. `Game::Message.scan` flags the code and `Scene::Map` builds and tears
  down the gold window with the message.
