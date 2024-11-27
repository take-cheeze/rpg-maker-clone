MRuby::Gem::Specification.new('mruby-rgss') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'RGSS implementation in mruby'

  cxx.include_paths << "#{dir}/../3rd/uni-algo/include"
  linker.library_paths << "#{ENV["PROJECT_BUILD_DIR"]}/3rd/uni-algo"
  linker.libraries << "uni-algo"
end
