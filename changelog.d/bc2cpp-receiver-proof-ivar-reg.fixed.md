- `scripts/bc2cpp/type_check.rb` without `--no-sends` no longer crashes with a
  `TypeError` in the receiver-proof report: the instance-variable store sites
  passed their register to the writer walk as a String instead of an Integer.
