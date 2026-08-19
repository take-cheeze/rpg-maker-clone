- **XP / VX / VX Ace** three more pieces of the "Ruby a real game's scripts
  assume, that this mruby build does not ship" gap (alongside the existing
  `Errno` fill-in): `Win32API` (RGSS's Windows-DLL FFI class — construction
  now always succeeds, and `#call` warns once and answers `0` rather than
  ending the whole script host over an optional Windows-only feature, e.g.
  the widely bundled CACAO 画像保存 screenshot-saving utility, which binds
  several Win32 calls unconditionally at script load time); `String#encode`
  (a no-op that answers the receiver unchanged and warns once — this build
  has no real transcoding tables, but nothing in this UTF-8-throughout engine
  ever depends on the boundary a script transcodes across, typically a
  Win32API argument); and `Module#private_method_defined?` /
  `#protected_method_defined?` / `#public_method_defined?` (real answers, not
  stubs — mruby-metaprog already tracks method visibility for
  `private_instance_methods` and friends, this just exposes the
  membership-check form scripts actually call). Found booting a real VX Ace
  release's bundled community utility scripts.
