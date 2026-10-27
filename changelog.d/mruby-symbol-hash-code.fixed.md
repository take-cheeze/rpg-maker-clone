- **mruby**: the fork pin moves to `claude/symbol-hash-code-k4p8`, where a Symbol Hash key is hashed by its id. Under
  64-bit word boxing every Symbol hashed to nearly the same value, so a large Symbol-keyed Hash was one bucket:
  20,000 keys took 7.2 s for an insert and three lookups each, now 13 ms.
