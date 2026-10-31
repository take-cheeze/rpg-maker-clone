- Fix the `bc2cpp-sweep` crash after eliminating `[]`/`[]=` from the method
  tables: a constant initializer like `ALL_DIRS = (DIR_BIT[2] | ...)` runs at
  gem-init load through a by-name send, which raised `NoMethodError` once the
  names left the tables and aborted the init before the instance-type setup
  ran. The loader keeps such calls out of its data, and both the decoder and
  the legacy emitters route `[]`/`[]=` through the shared index helpers.
