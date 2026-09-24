#!/usr/bin/env ruby
# frozen_string_literal: true

# wio-only build step (build_config.rb's wio_strip_unreachable): deletes from
# a build-time copy of one mrblib file every `def` that
# wio_unreachable_methods.rb found unreachable, and drops those names from
# the owner's private/protected/public/module_function lists, wherever in the
# closed world the list is. ADR 0218.
#
# Usage: ruby strip_wio_unreachable_methods.rb <unreachable.tsv> <input.rb> <output.rb>

require 'set'
require_relative 'strip_wio_bc2cpp_stubs'

# The statements strip_defs_from_source must shrink; wio_unreachable_methods.rb
# does not count their arguments as calls (its LIST_MIDS).
UNREACHABLE_LIST_MIDS = (VISIBILITY_MIDS + %i[module_function]).freeze

# {owner => Set[name]} from the analysis TSV (owner, name, gem, file, line).
def load_unreachable(tsv_path)
  File.foreach(tsv_path).each_with_object(Hash.new { |h, k| h[k] = Set.new }) do |line, h|
    owner, name, = line.chomp.split("\t")
    h[owner] << name if owner && name
  end
end

if __FILE__ == $PROGRAM_NAME
  tsv, in_path, out_path = ARGV
  raise ArgumentError, "usage: #{$PROGRAM_NAME} <unreachable.tsv> <input.rb> <output.rb>" unless out_path

  by_owner = load_unreachable(tsv)
  source = File.read(in_path, external_encoding: Encoding::UTF_8)
  File.write(out_path, strip_defs_from_source(source, by_owner, in_path, list_names_by_owner: by_owner,
                                                                          visibility_mids: UNREACHABLE_LIST_MIDS))
end
