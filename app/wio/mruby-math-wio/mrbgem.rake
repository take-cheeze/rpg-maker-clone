# The Wio Terminal's stand-in for mruby's core mruby-math gem: the Math
# module with only the members wio's own gems use. build_config.rb swaps it
# in for wio only; src/math.c's header comment and docs/adr/0204 have why.
MRuby::Gem::Specification.new('mruby-math-wio') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'Minimal Math module for the Wio Terminal (PI, E, sin)'
end
