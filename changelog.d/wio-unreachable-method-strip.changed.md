- **Wio Terminal:** the wio build now deletes every Ruby method nothing in
  the firmware can call, computed at build time by
  `scripts/wio_unreachable_methods.rb` over the wio closed world (call sites,
  Symbol/String literals, native C/C++ and VM hooks, with a worklist so
  methods only dead code calls go too). 110 methods go, saving 17,088 bytes of
  flash on the real ARM link. `scripts/wio_unreachable_methods_check.rb`
  checks the analysis on a fixture world in CI. See ADR 0218.
