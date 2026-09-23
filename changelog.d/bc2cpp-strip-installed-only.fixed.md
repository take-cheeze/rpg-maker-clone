- **A bc2cpp build can no longer strip the bytecode of a compiled method
  that nothing installs.** `tools/bc2cpp/wio_registered_methods.rb` tells
  `strip_wio_bc2cpp_stubs.rb` which interpreted `def`s have a C++ override,
  and it treated every method bc2cpp.rb *could* compile as registered. For an
  owner outside `BC2CPP_WIRED_EMBEDDINGS`, only the hand-written
  `register.cxx` installs the override, and it can lag behind. That is how
  RGSS::Audio's private file-resolution helpers and three
  `RGSS::Graphics` singletons were once left with no implementation at all:
  "undefined method 'find_encrypted_loose' for Module" on every RPG2000
  system sound effect. Wiring both owners (docs/adr/0197) fixed those
  instances. This closes the gap itself: the probe now prints only entries
  that a real registration call names, in `register.cxx` or in bc2cpp.rb's
  generated registrations (`bc2cpp_define_private_class_method` included),
  plus the deliberately unregistered docs/adr/0203 names. On today's tree
  that drops nothing.
