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

# RbConfig.ruby: the interpreter bc2cpp starts its tools with. Under mruby it is the wrapper tools/bc2cpp/mruby-ruby,
# which runs a tool through the mruby binary and its baked source; the build or the run sets BC2CPP_RUBY to it.
module RbConfig
  def self.ruby
    interpreter = ENV['BC2CPP_RUBY']
    raise LoadError, 'RbConfig.ruby: BC2CPP_RUBY is not set' unless interpreter

    interpreter
  end
end
MRubyRequire.provide('rbconfig') { defined?(RbConfig) }

# Enumerable#to_set, as CRuby's set library defines it. mruby-set leaves it out (its README lists it as unimplemented).
module Enumerable
  def to_set(klass = Set, *args, &block)
    klass.new(self, *args, &block)
  end
end

# RUBY_PLATFORM, which mruby does not define. bc2cpp keys its caches on it; "mruby" names the runtime that wrote them.
RUBY_PLATFORM = 'mruby' unless defined?(RUBY_PLATFORM)

# File.stat, reduced to what bc2cpp reads from it: the modification time and the size, taken from the open file (mruby-io
# has no stat). Any other field is absent, and a missing file raises as File.open does.
class File
  Stat = Struct.new(:mtime, :size) unless defined?(File::Stat)

  def self.stat(path)
    File.open(path, 'rb') { |io| File::Stat.new(io.mtime, io.size) }
  end
end

# File.readlines: the lines of a file. Options such as encoding: are accepted and not needed (text is read as bytes).
class File
  def self.readlines(path, *_options)
    File.read(path).lines
  end
end

# SystemCallError: mruby has no Errno, and its failed file operations raise RuntimeError, so the name stands for that class.
SystemCallError = RuntimeError unless defined?(SystemCallError)

# File.write, File.binwrite and File.binread, as CRuby defines them (mruby-io has the IO methods, not these).
class File
  def self.write(path, data)
    File.open(path, 'w') { |io| io.write(data) }
  end

  def self.binwrite(path, data)
    File.open(path, 'wb') { |io| io.write(data) }
  end

  def self.binread(path)
    File.open(path, 'rb') { |io| io.read }
  end
end

# Module#private_constant. mruby has no constant visibility, so the named constants stay public: a correct program
# behaves the same, and only code that would have raised NameError on a private constant can tell the difference.
class Module
  def private_constant(*_names)
    nil
  end
end

# File.read with the encoding: option. mruby-io's read takes no options; the bytes it reads are the file's, so the option
# only chooses the result's encoding, BINARY (the bytes as they are) or not (the text as read).
class File
  class << self
    alias __core_read read
  end

  def self.read(path, *args, **options)
    text = args.empty? ? __core_read(path) : __core_read(path, *args)
    options[:encoding].to_s.upcase == 'BINARY' ? text.b : text
  end
end

# Mutex, for the single thread mruby runs: no other thread can hold it, so a lock is only ever taken by the one caller.
# Locking it again while held raises ThreadError, as CRuby does for a recursive lock.
class ThreadError < StandardError; end unless defined?(ThreadError)

class Mutex
  def initialize
    @locked = false
  end

  def lock
    raise ThreadError, 'deadlock; recursive locking' if @locked

    @locked = true
    self
  end

  def unlock
    raise ThreadError, 'Attempt to unlock a mutex which is not locked' unless @locked

    @locked = false
    self
  end

  def try_lock
    return false if @locked

    @locked = true
  end

  def locked? = @locked

  def synchronize
    lock
    begin
      yield
    ensure
      unlock
    end
  end
end unless defined?(Mutex)
