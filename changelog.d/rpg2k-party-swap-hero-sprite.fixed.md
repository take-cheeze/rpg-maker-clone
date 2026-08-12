- **Change Party Member (10330)** now flags the on-map hero sprite for
  reload, the same one-shot request Change Sprite Association already
  raises. `Game::Party#leader` can change on every add/remove, and the
  sprite was only ever refreshed by an explicit Change Sprite Association --
  so a game that swaps its active party member (Nepheshel's whole companion
  system runs on this command, 5205 times) kept drawing whichever leader's
  CharSet happened to be cached.
- **`Scene::Title`'s title picture load** is now rescued like every other
  asset loader in the RPG2000/2003 scene stack (chipset, charsets,
  windowskins, `Scene::GameOver`'s game-over picture). A missing or
  unreadable `Title/` image used to raise unhandled, taking the engine down
  before a single frame was drawn -- indistinguishable, from outside, from a
  black screen on start.
