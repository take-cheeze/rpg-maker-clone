- **bc2cpp**: a declared `@items: Array[T]` now also types and guards loops and Integer reads through its attr_reader
  (`obj.items.each`) when the receiver's class is proven, and `ary[start, len]` on an exact Array is typed Array-or-nil.
  Generated init code resolves owner classes from one walked row per path instead of chained `mrb_const_get` calls
  (Wio flash -976 B). `BC2CPP_DECLARED_ELEMENT_READER=0`, `BC2CPP_ARRAY_SLICE2_RESULT=0` and
  `BC2CPP_CONST_PATH_WALK=0` turn the parts off.
