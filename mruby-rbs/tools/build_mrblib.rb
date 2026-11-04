# frozen_string_literal: true

# Builds the mruby-rbs mrblib: the RBS Ruby library (3rd/rbs/lib/rbs) in load order, with the parts that
# mruby does not provide replaced by mruby-compatible equivalents. Run by mrbgem.rake at build time.
#
#   ruby tools/build_mrblib.rb RBS_LIB_DIR FILE_LIST OUTPUT
#
# Deviations from the CRuby sources (each is a change of mechanism, not of the parsed result):
#   - Excluded: the test, unit_test, collection (package manager), CLI, runtime type-check, Prism and
#     TSort-based files, which parsing does not reach. The file list is the reviewed list.
#   - `require` / `require_relative` lines are dropped: the mrblib is one compiled unit.
#   - Mutex: mruby is single-threaded, so `@intern_mutex.synchronize do ... end` runs as a plain block.
#   - private_constant: mruby has no constant visibility; the calls are removed (the constants stay public).
#   - compare_by_identity: mruby has none. IdentityHash keys entries by object_id.
#   - Symbol#match?: added, delegating to String#match? as CRuby does.
#   - unpack1(..., offset:): mruby has no offset keyword; slice first with byteslice.

lib_dir, list_path, output = ARGV
abort 'usage: build_mrblib.rb RBS_LIB_DIR FILE_LIST OUTPUT' unless output

files = File.read(list_path, encoding: "UTF-8").split("\n").map(&:strip).reject(&:empty?)

PRELUDE = <<~RUBY
  class Symbol
    def match?(*args)
      to_s.match?(*args)
    end
  end

  class IdentityHash
    def initialize
      @h = {}
    end

    def [](key)
      entry = @h[key.object_id]
      entry && entry[1]
    end

    def []=(key, value)
      @h[key.object_id] = [key, value]
      value
    end

    def key?(key)
      @h.key?(key.object_id)
    end
  end
RUBY

def transform(text)
  text = text.gsub(/^\s*require(?:_relative)?\s*["'(].*\n/, '')
  text = text.gsub('@intern_mutex = Mutex.new', '@intern_mutex = nil')
  text = text.gsub('@intern_mutex.synchronize do', 'begin')
  text = text.gsub(/^\s*private_constant\b.*\n/, '')
  text = text.gsub('@intern_cache = {}  #: Hash[Namespace, Hash[Symbol, TypeName]]', '@intern_cache = IdentityHash.new')
  text = text.gsub("    @intern_cache.compare_by_identity\n", '')
  text = text.gsub("done = {} #: Hash[Definition, bool]\n              done.compare_by_identity", 'done = IdentityHash.new')
  text.gsub(/@bytes\.unpack1\(("[^"]+"), offset: @pos\)/, '@bytes.byteslice(@pos, 8).unpack1(\1)')
end

parts = [PRELUDE]
files.each do |file|
  parts << "# ---- #{file}\n" + transform(File.read(File.join(lib_dir, file), encoding: "UTF-8"))
end
File.write(output, parts.join("\n"), encoding: "UTF-8")
puts "wrote #{output} (#{files.size} files)"
