# Features provided by the build, as name => check. A check returns true when the code it names is present.
module MRubyRequire
  FEATURES = {}
  SOURCES = {}
  LOADED = {}

  def self.provide(name, &check)
    FEATURES[name] = check
  end

  # A baked source (tools/bc2cpp/bake_sources.rb): its code is evaluated under its own name, once, by require.
  def self.bake(name, source)
    SOURCES[name] = source
  end
end

module Kernel
  def require(name)
    feature = name.to_s
    return false if MRubyRequire::LOADED[feature]

    if (source = MRubyRequire::SOURCES[feature])
      MRubyRequire::LOADED[feature] = true
      eval(source, nil, feature)
      return true
    end

    check = MRubyRequire::FEATURES[feature]
    raise LoadError, "cannot load such file -- #{feature}" unless check && check.call

    MRubyRequire::LOADED[feature] = true
    true
  end
end

MRubyRequire.provide('set') { defined?(Set) }
MRubyRequire.provide('stringio') { defined?(StringIO) }

# The standard libraries this build's gems stand in for (each named by its gem's constant or method).
MRubyRequire.provide('json') { defined?(JSON) }
MRubyRequire.provide('digest') { defined?(Digest) }
MRubyRequire.provide('fileutils') { defined?(FileUtils) }
MRubyRequire.provide('tmpdir') { defined?(Dir) && Dir.respond_to?(:mktmpdir) }
MRubyRequire.provide('shellwords') { defined?(Shellwords) }
MRubyRequire.provide('strscan') { defined?(StringScanner) }
MRubyRequire.provide('tempfile') { defined?(Tempfile) }
MRubyRequire.provide('zlib') { defined?(Zlib) }
MRubyRequire.provide('prism') { defined?(Prism) }
MRubyRequire.provide('rbs') { defined?(RBS) }
MRubyRequire.provide('open3') { defined?(Open3) }
