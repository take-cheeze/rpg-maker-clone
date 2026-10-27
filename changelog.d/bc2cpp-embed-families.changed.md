- **bc2cpp** now embeds the ivars of a class family, a base plus subclasses
  that each have their own, in the base's struct when every subclass
  `#initialize` starts with `super` (`docs/bc2cpp-embed-families.md`). The
  optcarrot APU channels embed this way, and 1800 frames drop from 8.9 s to
  8.0 s.
