- **Wio Terminal**: libmruby is built with link-time optimisation (about 96 KB
  less flash); the Arduino core stays non-LTO so the vector table survives.
  `scripts/wio/vector_table_check.rb` checks a linked image's vector table.
  `WIO_LTO=0` turns it off.
