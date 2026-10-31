- The bc2cpp resumable step compiler (`tools/bc2cpp/codegen_resumable.rb`) now
  accepts a method with optional positional arguments and a block parameter
  (`def count(item = nil, &block)`), using the jump table the core compile already
  recognises. Such methods (`Array#fetch`, `Array#find`, `Enumerable#count`,
  `Hash#fetch`, `Integer#step`, `Float#step`, `String#upto`, `String#each_line`)
  can now get a resumable variant. `BC2CPP_RESUMABLE_DUAL` (a comma list of
  `Owner#name`, probe only) and `BC2CPP_RSM_DEBUG=1` report why a variant is refused.
