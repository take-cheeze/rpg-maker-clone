MRuby::Build.new do |_conf|
  toolchain

  enable_test

  gem mgem: 'mruby-marshal'
  gem mgem: 'mruby-onig-regexp'

  gem core: 'mruby-array-ext'
  gem core: 'mruby-hash-ext'
  gem core: 'mruby-io'

  gem "#{MRUBY_ROOT}/../../mruby-rgss"
end
