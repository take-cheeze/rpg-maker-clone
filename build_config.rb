MRuby::Build.new do |_conf|
  toolchain

  enable_test

  gem core: 'mruby-array-ext'
  gem core: 'mruby-hash-ext'
  gem core: 'mruby-io'

  gem "#{MRUBY_ROOT}/../mruby-stringio"
  gem "#{MRUBY_ROOT}/../mruby-marshal"
  gem "#{MRUBY_ROOT}/../mruby-onig-regexp"

  gem "#{MRUBY_ROOT}/../../mruby-rgss"
  gem "#{MRUBY_ROOT}/../../mruby-lcf"
end
