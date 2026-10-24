- **bc2cpp: block sends to `!`/`?` core methods keep their direct arms.** The
  BLOCK_ARM_REACH check that matches each live `_impl` call to a counted one
  read the C++ name with `\w+`, but `reject!`/`any?` compile to
  `Array_reject$21_impl`/`Enumerable_any$3f_impl`, so the arms were dropped and
  the send stayed on `mrb_funcall_with_block`. In the closed world all 18
  `any?` and 3 `reject!` block sends now call the compiled core body, and
  `mrb_funcall_with_block` calls drop from 311 to 287. Covered by
  `scripts/bc2cpp/block_iterator_direct_check.rb`.
