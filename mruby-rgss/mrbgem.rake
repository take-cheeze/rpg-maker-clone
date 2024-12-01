MRuby::Gem::Specification.new('mruby-rgss') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'RGSS implementation in mruby'

  cxx.include_paths <<
    "#{dir}/../3rd/uni-algo/include" <<
    "#{dir}/../3rd/lvgl" <<
    "#{dir}/../include" <<
    "#{dir}/../3rd/stb"
  linker.library_paths << "#{ENV["PROJECT_BUILD_DIR"]}/3rd/uni-algo" << "#{ENV["PROJECT_BUILD_DIR"]}/3rd/lvgl/lib"
  linker.libraries << "uni-algo" << "lvgl"
end
