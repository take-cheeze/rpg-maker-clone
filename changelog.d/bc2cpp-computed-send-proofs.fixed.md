- **bc2cpp** the entry-argument and Fixnum-return proofs (and the call-site
  argument types behind embedded ivars) now refuse every method name a
  computed-name `send`/`public_send`/`method`/`define_method` could reach, so a
  String passed through `send("#{field}=", v)` is no longer read as a Fixnum.
  New `scripts/bc2cpp_computed_send_proof_check.rb`. See
  `docs/adr/0279-bc2cpp-overflow-exact-fixnum-tier.md`.
