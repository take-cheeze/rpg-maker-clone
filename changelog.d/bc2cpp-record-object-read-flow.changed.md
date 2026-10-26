- **bc2cpp**: record-hash reads propagate proven constructed-object classes
  through class pools, removing downstream guards and dispatch. Missing/deleted
  keys retain nilability, and escaped records or unknown writers remain unproven.
