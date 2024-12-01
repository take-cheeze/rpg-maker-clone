MRuby::Build.new do |_conf|
  toolchain :gcc

  enable_test
  enable_debug

  [cc, cxx].each do |t|
    t.flags = t.flags.flatten.delete_if {|v| v == "-O0" }
  end

  gem core: 'mruby-array-ext'
  gem core: 'mruby-hash-ext'
  gem core: 'mruby-io'

  gem "#{MRUBY_ROOT}/../mruby-stringio"
  gem "#{MRUBY_ROOT}/../mruby-marshal"
  gem "#{MRUBY_ROOT}/../mruby-onig-regexp"

  gem "#{MRUBY_ROOT}/../../mruby-lcf"
  gem "#{MRUBY_ROOT}/../../mruby-rgss"
  gem "#{MRUBY_ROOT}/../../mruby-rpg2k"
end
