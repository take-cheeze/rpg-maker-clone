- **A singleton class no longer has an instance-variable table just for
  `__attached__`** (mruby fork: SCLASS_ATTACHED). This frees 9.1 KB of the
  Wio Terminal's heap on every scene (231 singleton classes).
