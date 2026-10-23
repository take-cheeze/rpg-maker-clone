- The compiled optcarrot benchmark builds when run under `bundle exec`. Its mruby
  build now drops the bundle's `RUBYOPT`, `RUBYLIB` and `BUNDLE*`/`BUNDLER*`
  variables, which made the mruby tree's own Ruby processes fail to resolve its
  `yard` gem.
