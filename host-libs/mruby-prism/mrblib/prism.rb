# frozen_string_literal: true

# Prism.parse for mruby: the same entry point CRuby's prism gem has. The C core parses the source and serializes the
# AST (Prism::Native.parse_serialized); the Ruby half (tools/build_mrblib.rb) decodes it into Prism::Node objects.
module Prism
  def self.parse(source)
    source = source.dup
    serialized = Native.parse_serialized(source).force_encoding(Encoding::BINARY)
    Serialize.load_parse(source, serialized, false)
  end
end
