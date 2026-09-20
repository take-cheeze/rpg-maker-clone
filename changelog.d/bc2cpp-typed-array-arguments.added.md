- bc2cpp now accepts `Array<Klass>` argument annotations and uses them to
  devirtualize calls on proven array elements with an exact-class guard and
  Ruby-dispatch fallback. RPG2k battle ally and enemy loops now use this hint.
