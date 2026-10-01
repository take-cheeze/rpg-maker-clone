- **bc2cpp RGSS native result facts (ADR 0302).** The numeric, exact-class and Fixnum proofs now know what the
  RGSS getters return: `Bitmap#width`/`height` and `Rect#x`/`y`/`width`/`height` are small Integers,
  `Color`/`Tone` components are Floats, `Bitmap#rect`/`text_size` are an exact `RGSS::Rect`. Each fact pins its
  native registration and return statements and is re-audited by `scripts/bc2cpp_native_result_facts_check.rb`
  (which also rejects source mutants). A zero-argument native wrapper on a receiver proven exactly its class is a
  direct call without the class-guard chain, and a send whose receiver is proven to hold only instances (and
  `nil`) ignores a `def self.x` definer of the same name. On the wio closed world: 38 fewer `bc2cpp_send` sites,
  19 fewer numeric slow-path calls, 37 fewer `singleton_definer` fallbacks; three reviewed `nomethod` keys added.
