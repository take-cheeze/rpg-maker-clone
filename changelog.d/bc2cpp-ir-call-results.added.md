- **bc2cpp** propagates audited call-result proofs and ordinary explicit-receiver
  RBS return contracts through IR queries, including bounded call chains and
  receiver unions. Reports distinguish contract-derived returns from independent
  inference; normal RBS return contracts are refused for block calls whose
  nonlocal exits can replace the result.
