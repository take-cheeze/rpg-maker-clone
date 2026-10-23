- The bc2cpp escape analysis no longer treats the receiver of an implicit-self
  `raise` as escaping: `Kernel#raise` never keeps or returns its receiver, so a
  method that raises can keep its `self` confined. The raised exception and
  its message are still treated as kept.
