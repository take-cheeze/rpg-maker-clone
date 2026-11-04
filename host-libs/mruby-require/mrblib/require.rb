# Features provided by the build, as name => check. A check returns true when the code it names is present.
module MRubyRequire
  FEATURES = {}
  LOADED = {}

  def self.provide(name, &check)
    FEATURES[name] = check
  end
end

module Kernel
  def require(name)
    feature = name.to_s
    return false if MRubyRequire::LOADED[feature]

    check = MRubyRequire::FEATURES[feature]
    raise LoadError, "cannot load such file -- #{feature}" unless check && check.call

    MRubyRequire::LOADED[feature] = true
    true
  end
end

MRubyRequire.provide('set') { defined?(Set) }
MRubyRequire.provide('stringio') { defined?(StringIO) }
