- **bc2cpp**: `scripts/bc2cpp/prune_static_dispatch_registrations.rb` removes
  hand-written `register.cxx` lines only for names every target leaves
  unregistered (base list and closed list intersection; 3 names). A new
  `--check` mode runs in the bc2cpp gate and fails if a shared-unregistered name
  is registered by hand. Names unregistered only by the closed build keep their
  registration, since `register.cxx` is shared by every target.
