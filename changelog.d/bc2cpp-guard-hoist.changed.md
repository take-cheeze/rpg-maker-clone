- **bc2cpp** (GUARD_HOIST): a receiver class test that an earlier test of the same unchanged value already
  decided (its else raises NoMethodError) is no longer repeated; the chain keeps only the arms up to the one the
  proven classes reach. This saves 9,096 B of Wio flash (2,180,508 -> 2,171,412 B). `BC2CPP_GUARD_HOIST=0`
  keeps every test.
