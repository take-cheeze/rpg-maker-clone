- **bc2cpp** core-exact-direct check now covers the pooled `Hash#delete` /
  `Hash#fetch` flow-core path introduced by ADR 0323, and retargets its
  surviving mutant to the FLOW_CORE_DIRECT early return. No generator change.
