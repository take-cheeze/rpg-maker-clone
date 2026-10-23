#!/usr/bin/env ruby
# frozen_string_literal: true

# Wio-only experiment: replaces the body of every engine-owned Ruby method that bc2cpp compiles to C++ with a
# runtime raise. The header (name and parameters) is untouched; the compiled body is what runs, and the stub is
# what an uncompiled or unregistered call reaches, so it raises rather than running stale bytecode.
#
# Usage: ruby scripts/wio/stub_compiled_bodies.rb <compiled-methods.txt> <in.rb> <out.rb>
#   compiled-methods.txt: the first field of each bc2cpp "// Owner#name (compiled from irep ...)" header, one per
#   line; "Owner.singleton#name" for singleton methods.
# One-line and endless defs are left alone and counted.

require 'prism'
require 'set'

module WioStubCompiled
  module_function

  def wanted_keys(list_path)
    File.readlines(list_path, chomp: true).map { |l| l.split(' ', 2).first }.to_set
  end

  # Returns [stubbed source, stubbed count, left-alone count].
  def stub(source, wanted, path)
    tree = Prism.parse(source)
    raise "#{path}: does not parse: #{tree.errors.first.message}" unless tree.errors.empty?

    edits = []
    skipped = 0
    walk(tree.value, [], false) do |node, owner, singleton|
      key = "#{owner}#{singleton ? '.singleton' : ''}##{node.name}"
      next unless wanted.include?(key)

      # A rescue/ensure body is a BeginNode whose location starts at the header: left alone.
      # Writers of instance variables stay: the RBS ivar declarations rely on them.
      writes_ivar = node.body && node.body.breadth_first_search { |n| n.is_a?(Prism::InstanceVariableWriteNode) || n.is_a?(Prism::InstanceVariableOrWriteNode) || n.is_a?(Prism::InstanceVariableOperatorWriteNode) }
      if writes_ivar || node.end_keyword_loc.nil? || node.location.start_line == node.location.end_line || node.body.is_a?(Prism::BeginNode)
        skipped += 1
        next
      end
      indent = source.lines[node.end_keyword_loc.start_line - 1][/\A\s*/]
      stub_line = "raise \"bc2cpp stub: #{key}\"\n#{indent}"
      if node.body
        edits << [node.body.location.start_offset, node.end_keyword_loc.start_offset, stub_line]
      else
        edits << [node.end_keyword_loc.start_offset, node.end_keyword_loc.start_offset, "  #{stub_line}"]
      end
    end
    [apply(source, edits), edits.size, skipped]
  end

  def walk(node, owner, singleton, &block)
    return unless node.is_a?(Prism::Node)

    case node
    when Prism::ClassNode, Prism::ModuleNode
      name = node.constant_path.slice
      walk(node.body, owner + [name], false, &block) if node.body
      return
    when Prism::SingletonClassNode
      walk(node.body, owner, true, &block) if node.body
      return
    when Prism::DefNode
      yield node, owner.join('::'), singleton || node.receiver.is_a?(Prism::SelfNode)
      return
    end
    node.compact_child_nodes.each { |c| walk(c, owner, singleton, &block) }
  end

  # Applies non-overlapping edits from the end so earlier offsets stay valid.
  # Prism offsets are bytes, so the edits run on the binary form of the source.
  def apply(source, edits)
    out = source.b
    edits.sort_by { |s, _, _| -s }.each { |s, e, text| out[s...e] = text.b }
    out.force_encoding(Encoding::UTF_8)
  end
end

if $PROGRAM_NAME == __FILE__
  list, input, output = ARGV
  abort 'usage: stub_compiled_bodies.rb <compiled-methods.txt> <in.rb> <out.rb>' unless output
  source = File.read(input, encoding: 'UTF-8')
  stubbed, count, skipped = WioStubCompiled.stub(source, WioStubCompiled.wanted_keys(list), input)
  tree = Prism.parse(stubbed)
  raise "#{input}: stubbed source does not parse: #{tree.errors.first.message}" unless tree.errors.empty?

  File.write(output, stubbed, encoding: 'UTF-8')
  warn "stub_compiled_bodies: #{count} stubbed, #{skipped} left alone in #{input}"
end
