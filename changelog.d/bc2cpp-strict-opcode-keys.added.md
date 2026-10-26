- **bc2cpp:** opcode-keyed tables (`OperandSchema::SCHEMAS`) now use a
  `StrictKeyHash` that raises `TypeError` on a non-Symbol key in dev
  instead of missing silently; `BC2CPP_STRICT_KEYS=0` aliases it to a
  plain `Hash` for production (zero overhead, identical semantics).
