- **`Game::States.message` is now `compose_message`** so bc2cpp can
  devirtualize its four bare self-calls: `message` also names
  `Exception#message`, which kept the name out of reach of the lexical-self
  proof. Behaviour is unchanged.
