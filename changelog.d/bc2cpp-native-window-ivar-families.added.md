- **bc2cpp** scopes audited native `@contents` and `@cursor_rect` accesses to the RGSS::Window family, allowing unrelated
  Ruby families to pool their own slots, including `@viewport` scoped to RGSS::Sprite/Plane/Tilemap/Window.
  The Wio census loses 43 cached by-name engine sends, adding 39 nil-receiver
  helper calls. Pinned source changes, new native callers and outside ivar spellings withdraw the proof;
  `BC2CPP_NATIVE_IVAR_SCOPES=0` restores global poisoning (ADR 0332).
