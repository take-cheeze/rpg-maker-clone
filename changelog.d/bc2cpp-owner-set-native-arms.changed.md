- **bc2cpp**: more owner calls skip the method lookup (`tools/bc2cpp/codegen_owner_set_direct.rb`).
  - `dup`, `object_id` and `__to_int`, whose owners are Kernel (and Module for `dup`), are computed in place. `dup`
    keeps the owner call for a class or module receiver, the only kind Module's own `dup` can answer.
  - OWNER_SET_NATIVE_ARMS: exact-class arms in front of the owner call, each calling an audited mruby core body
    (`NativeCoreDirect::OWNER_ARM_ENTRIES`, plus the existing `Integer#to_i` and `Integer#to_s` rows):
    - `to_i` on an Integer, or on a finite Float in the fixnum range;
    - `to_f` on an Integer or a Float;
    - `<=>` between fixnums, or between a fixnum or Float and a Float;
    - `bytesize` on an exact String;
    - `keys` on an exact Hash.

    Any other receiver or argument, such as a NaN or out-of-range Float, a heap Integer, a String subclass or
    `nil`, keeps the owner call. `BC2CPP_OWNER_SET_DIRECT=0` turns both off.
