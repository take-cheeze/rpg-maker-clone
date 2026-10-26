- **bc2cpp**: the closed build no longer keeps a compiled method registered just because its name appears as a
  Symbol literal: a hash key, a `when` label or a `respond_to?` argument.
  - `static_dispatch_symbol_uses.rb` checks that every name-taking call in the closed bytecode passes a literal:
    `send`, `method`, `inject`, `to_enum` and `&:name` blocks. When that holds, only those literals name a method.
  - `respond_to?` still answers true for the methods the build leaves out of the tables. `bc2cpp_left_out` records
    their classes, and the generated `mrb_respond_to` and a closed-build `Kernel#respond_to?` consult that table.
  - Hand-registration guards now read `#else bc2cpp_left_out(...)`; the old verify-stub branch moved into that helper.
