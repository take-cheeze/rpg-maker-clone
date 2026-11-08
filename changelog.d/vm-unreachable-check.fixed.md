- **Build:** the closed build now checks that its bytecode interpreter loop stays compiled out, and the host sweep
  fails if the VM-free stub is ever reached.
