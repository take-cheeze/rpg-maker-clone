- Closed-world receiver analysis now treats symbolic unknown-class sentinels as
  unprovable instead of raising, directly calls 328 singleton sites on stable
  class/module constants (including qualified constants whose identity is
  carried through the VM register), including 269 safe `module_function`
  copies via their original body, and refreshes the reviewed dead-fallback set.
