- **bc2cpp:** avoid redundant wide-mask unions during numeric dataflow joins
  and register-name strings when no captured registers are opaque, reducing
  allocations without changing inference results or generated C++.
