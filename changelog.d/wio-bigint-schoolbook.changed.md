- The Wio Terminal build multiplies and prints big Integers with the
  schoolbook methods only (`MRB_BIGINT_SCHOOLBOOK`), which drops the
  Karatsuba/Toom-3 code from flash. Results are unchanged;
  `WIO_BIGINT_FAST=1` keeps the faster algorithms.
