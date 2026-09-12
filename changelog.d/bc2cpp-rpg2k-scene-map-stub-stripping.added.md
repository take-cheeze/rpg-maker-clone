- The wio, `RPGMAKER_BC2CPP=1` build now also strips the interpreted-
  bytecode body of every one of `RPG2k::Scene::Map`'s (the field-map
  scene class) 224 real `mruby-rpg2k-compiled`-registered methods out of
  its own copy of `mruby-rpg2k/mrblib/scene/map.rb` (docs/adr/0144's own
  `wio_strip_bc2cpp_stubs` mechanism, extended to a 55th owner) -- the
  largest single owner this series has covered, a real measured 196,252
  -> 122,052 byte (37.8%) reduction on that one file (host `mrbc -g`).
- Two real `public :name1, :name2, ...` statements in `scene/map.rb`
  named both a bc2cpp-registered (now-stripped) method and a kept one in
  the same call -- the one companion-statement shape
  `strip_wio_bc2cpp_stubs.rb` has always refused to guess at rather than
  risk a wrong partial edit. Split each into two homogeneous statements
  (one all-kept, one all-stripped) instead of changing that shared
  script: `Module#public` called twice with disjoint subsets of the same
  name set has the exact same effect as calling it once with the union,
  so this is a behaviorally inert refactor for every build, verified by a
  real `diff` showing the split has zero effect on any already-shipped
  owner's own stripped output.
