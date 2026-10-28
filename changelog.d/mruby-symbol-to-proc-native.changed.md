mruby fork: native `Symbol#to_proc`, no VM entry

`Symbol#to_proc` was a Ruby method that built a lambda per conversion; the
closed build compiled the call sites but still ran it as bytecode (720 VM starts
in the battle scenario, from `reject(&:dead?)` and similar). The fork now makes
a cfunc lambda that sends the Symbol to its first argument with `__send__`
semantics (private methods callable, `method_missing`, keywords and block
forwarded), so conversions and calls stay out of the VM. `Proc#arity` of the
result is -1 instead of -2 and `parameters` is empty. The 3rd/mruby pin moves to
`claude/symbol-to-proc-native` (`mrblib/symbol.rb` is gone).

bc2cpp: the block-self world proof (`block_self_world.rb`) holds the native
`Symbol#to_proc` (`src/symbol.c`) to the proof `symbol.rb`'s send had: the
Symbols the program passes as blocks must include no rebinder.
