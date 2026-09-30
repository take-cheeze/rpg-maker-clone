- **bc2cpp** gives a record-like Hash held in an ivar (`Scene::Battle#@ui`) a whole-program class
  per Symbol key, so `@ui[:battle].x` and `@ui[:events].x` become unguarded exact-class calls
  (27 fewer cached dynamic-dispatch sites in the wio build). Any use of the Hash beyond
  `h[key]`, `h[:lit] = v` and `h.delete(:lit)` refuses it. `BytecodeIR#reaching_definitions`
  gains `through_handlers:`. The LCF schema is exposed as a read-class oracle for a later
  receiver-binding pass. Covered by `scripts/bc2cpp_record_hash_check.rb`
  ([ADR 0285](docs/adr/0285-bc2cpp-record-hash-typing.md)).
