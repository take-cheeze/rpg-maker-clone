- **bc2cpp** admits a native-defined class (one binding, no writes anywhere in the closed world) to the unique-name
  table, so a bare `Rect.new` resolves to `RGSS::Rect`. The `Rect`/`Color`/`Tone` constructors drop their runtime
  class-identity guard. See `docs/bc2cpp-constant-lookup.md`, "Native-only classes".
