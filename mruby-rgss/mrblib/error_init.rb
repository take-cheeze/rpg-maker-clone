# NameError#initialize and NoMethodError#initialize, as mruby's own mrblib/10error.rb defines them.
#
# 10error.rb stays out of the compiled core Ruby (compiled_gems.rb, BC2CPP_CORE_MRBLIB_EXCLUDED): compiled, its
# `attr_accessor`s would put NameError#name and NoMethodError#args into the registry and add arms to every `.name`
# and `.args` call. These two constructors are the only bytecode of that file a method table keeps, so they are
# written here, where the build compiles them like any engine method and registers the compiled body over the
# interpreted one, and over 10error.rb's. The superclasses are the ones 10error.rb gives; the bodies are its own.
class NameError < StandardError
  def initialize(message = nil, name = nil)
    @name = name
    super(message)
  end
end

class NoMethodError < NameError
  def initialize(message = nil, name = nil, args = nil)
    @args = args
    super(message, name)
  end
end
