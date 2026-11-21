- **Wio Terminal: the VM-free firmware no longer runs bytecode at boot.** Under bc2cpp the wio libmruby defines
  `MRB_VM_FREE`, but it still loaded the core and gem mrblib as bytecode, so `mrb_open_core` raised "bytecode
  interpreter is not built in". wio now uses the closed build's VM-free set-up (the core and every gem run their
  compiled class units), and compiles `LCF::Schema` from `schema.rb` instead of loading the generated blob.
