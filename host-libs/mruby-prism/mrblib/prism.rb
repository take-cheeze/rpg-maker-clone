# frozen_string_literal: true

# Prism.parse for mruby: the same entry point CRuby's prism gem has. The C core parses the source and serializes the
# AST (Prism::Native.parse_serialized); the Ruby half (tools/build_mrblib.rb) decodes it into Prism::Node objects.
module Prism
  # filepath: and the other options name diagnostics and the like, which this parse does not produce; they are accepted.
  def self.parse(source, **_options)
    source = source.dup
    serialized = Native.parse_serialized(source).force_encoding(Encoding::BINARY)
    Serialize.load_parse(source, serialized, false)
  end
end

module Prism
  # The pinned fork is v1.9.0 (host-libs/mruby-prism/mrbgem.rake); bc2cpp keys its caches on this version.
  VERSION = '1.9.0' unless const_defined?(:VERSION)
end
