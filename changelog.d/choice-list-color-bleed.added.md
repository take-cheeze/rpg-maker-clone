- **A `\c[]` colour left open in a Show Text now bleeds into an attached
  Show Choices list merged into the same window**, matching yado.tk — an
  explicit `\c[0]` in the text is needed to stop the choices inheriting it.
  `Game::Message.scan` takes an optional starting colour and reports the
  colour still in effect at the end of the line; `Scene::Map` threads a
  Show Text's trailing colour into the choice labels appended onto it
  (chained across the labels themselves too), rather than always starting
  choices at colour 0. The matching `\s[]` (speed) half of the yado.tk
  finding is not addressed — this codebase drops `\s[]` outright, so there
  is no speed state yet to bleed.
