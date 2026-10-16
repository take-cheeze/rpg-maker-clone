- **bc2cpp** (ADR 0477): a literal block handed to `instance_exec`/`instance_eval`/`class_eval`/`define_method`/
  `Class.new`/`Struct.new` was compiled with its creator's `self`, so the compiled run read the wrong object (for
  example `o.instance_exec(3) { |k| [@tag, k] }` gave `[:creator, 3]` instead of `[:target, 3]`). Such blocks, and the
  blocks nested in them, now stay interpreted. A new world analysis (`tools/bc2cpp/block_self_world.rb`) reads every
  Ruby and native source of the closed world. It proves that no rebinder receives any other Proc, or names the site
  where one may. Where it may, as in the wio world through Enumerator#each's `__send__ @meth, ..., &block`, every
  compiled block checks at entry that it runs under the self it captured. A rebound compiled block raises
  `BC2cppGuardViolation` instead of running with the wrong self. When the world fact holds, BLOCK_SELF answers the
  creating method for blocks handed to native iterators. PROVEN_MISS now refuses `self` only inside rebound blocks.
  New check `scripts/bc2cpp/block_self_world_check.rb`.
