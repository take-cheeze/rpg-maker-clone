- Message text now **reveals gradually** (RPG2000's typewriter effect) instead
  of appearing all at once. A pure `Game::TextReveal` cursor exposes the
  already-expanded lines a couple of characters per frame; `Scene::Map` redraws
  the window as it fills and, on a button press, first completes the reveal and
  only dismisses the message once it is fully shown. Choice lists still appear at
  once. Covered by new checks in `scripts/rpg2k_logic_check.rb` and
  `scripts/rpg2k_scene_check.rb`.
