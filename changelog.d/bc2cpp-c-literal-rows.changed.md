- **bc2cpp closed build:** the core rows proof reads more C literals as what they are: an interned name, a local
  named as its own symbol, an exception message's words and the generated code's own locals. `Kernel#send`,
  `Kernel#public_send` and `Module#protected` leave the method table (596 to 593 entries).
