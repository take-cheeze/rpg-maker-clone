- The optcarrot probe now calls CPU opcode handlers with fixed positional
  arguments, avoiding the temporary Array created by `send(*dispatch)` in
  interpreted mruby runs while preserving the existing dispatch table.
