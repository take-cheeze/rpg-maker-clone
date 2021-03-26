MRuby::Gem::Specification.new('mruby-lcf') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'LCF data loader'

  add_dependency 'mruby-io'
  add_dependency 'mruby-pack'

  add_test_dependency 'mruby-stringio'
end
