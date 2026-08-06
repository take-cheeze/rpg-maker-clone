- **A Tint Screen tints the map for real.** It was approximated by a black
  overlay whose opacity tracked how far the tone's channels averaged *below*
  neutral, so three of the four things the command can ask for did nothing:
  brightening, the colour cast and saturation. Every map sprite now lives in one
  `Viewport` and `Scene::Map#update_map_tone` sets that viewport's tone from
  `Game::Screen#tint`, reusing the RPG2000→RGSS conversion the pictures already
  use (saturation included, which RPG2000 counts down and RGSS counts up).
  A viewport tints the sprites inside it and nothing else, which is the line the
  screen tone needs: the map is tinted while pictures, the message window and the
  weather / flash / fade overlays are not.
