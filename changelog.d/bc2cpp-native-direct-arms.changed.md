- **bc2cpp** calls the shared RGSS native entry points behind exact-class
  guards for the remaining setters and getters (`z=`, `visible=`, `x=`, `y=`,
  `color=`, `contents=`, `windowskin=`, `cursor_rect=`, `active=`, `pause=`,
  `flash`, ...), with an argument type guard that dispatches on a mismatch. In
  a closed world (wio/psp/maix) those arms let the chain's fallback become a
  proven NoMethodError: `core_or_native` kept fallbacks fall from 1,390 to 381
  and dead-fallback (`bc2cpp_nomethod`) sites rise from 3,065 to 3,750.
  See `docs/adr/0253-bc2cpp-native-direct-entry-points.md`.
