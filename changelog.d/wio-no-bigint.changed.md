- **Wio** links no `mruby-bigint` any more: its Ruby holds no integer literal
  past 32 bits (checked by `scripts/wio/bignum_literal_check.rb` in
  `scripts/wio/build.bash`), and the LCF codecs and the engine's wide
  arithmetic are native. About 24 KB of flash. `WIO_BIGINT=1` keeps the gem;
  `BC2CPP_CLOSED_WIO_INT=1` builds the closed host with the same integer model
  for a host sweep.
