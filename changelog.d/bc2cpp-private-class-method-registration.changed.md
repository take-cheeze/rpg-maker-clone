- **bc2cpp**: private singleton methods are now installed as compiled, still
  private, methods. `RGSS::Audio` and `RGSS::Graphics` now run all their
  compiled methods, and `RGSS::Audio.play_packed` is private again in bc2cpp
  builds. See ADR 0197.
