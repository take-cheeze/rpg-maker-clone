- **bc2cpp**: the `RPG2k::Scene` classes keep their instance variables in one
  compiled struct shared by `Scene::Base` and its subclasses, so compiled scene
  code reads them directly instead of looking each one up by name, and every
  compiled store into such a slot goes through one shared helper. The Wio
  firmware is about 31 KB smaller.
