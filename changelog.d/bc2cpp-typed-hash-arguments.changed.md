- bc2cpp now accepts `Hash<Klass>` argument annotations and uses them to
  devirtualize calls on indexed Hash values with runtime guards and Ruby
  fallbacks. The map picture signature uses this for its `Game::Picture`
  values.
