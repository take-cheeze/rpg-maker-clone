# Source-less stand-in for mruby-fiber in the closed build: the program supplies Fiber (bc2cpp_fiber_define).
MRuby::Gem::Specification.new('mruby-fiber') do |spec|
  spec.license = 'MIT'
  spec.authors = 'bc2cpp'
  spec.summary = 'placeholder: no sources, no mrb_fiber_* symbols'
end
