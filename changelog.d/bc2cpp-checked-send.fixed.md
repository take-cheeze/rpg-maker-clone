- **bc2cpp** by-name sends now raise what the VM raises: an explicit-receiver
  send of a private or protected method is a `NoMethodError`, and an
  `attr_reader` called with arguments is an `ArgumentError` (ADR 0299, covered
  by `scripts/bc2cpp_checked_send_check.rb`).
