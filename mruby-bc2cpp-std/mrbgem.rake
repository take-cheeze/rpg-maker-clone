# The standard streams' init as native code (closed build only, see build_config.rb). mruby-io's mrblib makes
# STDIN/STDOUT/STDERR and $stdin/$stdout/$stderr by calling __bc2cpp_std_init, which runs in its place: the gem is
# declared before mruby-io, so the method exists when the mrblib runs, and the IO class it opens is mruby-io's
# own (created by mruby-io's native init).
MRuby::Gem::Specification.new('mruby-bc2cpp-std') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'Native init of the standard streams for the closed build'
end
