- **Wio Terminal**: a Ruby exception no longer stops the firmware in
  `std::terminate`. The firmware links the full libsupc++'s `__cxa_throw`,
  which has unwind tables, instead of the nano one, which does not.
  `scripts/wio/vector_table_check.rb` checks it. `WIO_NANO_EH_THROW=1` keeps
  the nano one.
