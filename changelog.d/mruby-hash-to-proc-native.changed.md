mruby fork: native `Hash#to_proc`, no VM entry

`Hash#to_proc` (mruby-hash-ext) was a Ruby method returning the lambda
`->x{self[x]}`, one of the four bytecode bodies the closed build's method table
still held. The fork now makes a strict cfunc proc that keeps the Hash in its env
and reads it with `[]` (a subclass's `[]`, the default value and the default proc
apply; exactly one argument). `Proc#arity` of the result is -1 instead of 1 and
`parameters` is empty. The 3rd/mruby pin moves to `claude/hash-to-proc-native`.
