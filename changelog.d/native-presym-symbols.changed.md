- The RGSS native code names its methods, instance variables and constants with
  compile-time symbols, so a frame no longer looks any symbol up by name (about 40
  lookups per frame before).
