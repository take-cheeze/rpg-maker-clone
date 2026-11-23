- **bc2cpp**: an element read's GC root is dropped when every call it guards against is proven harmless by a
  whole-unit callee summary (`BC2CPP_ELEMENT_READ_SUMMARY=0` keeps them). A direct call of an operator or
  `?`/`!` method is now seen as a call, so an element held across one is rooted.
