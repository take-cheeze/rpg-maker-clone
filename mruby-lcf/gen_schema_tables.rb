#!/usr/bin/env ruby
# frozen_string_literal: true

# SCHEMA_TABLES: folds the `elements: -> { {...} }` lambdas of mrblib/schema.rb into data.
#
# Each of the 18 lambdas builds one record type's field table (DATABASE's player, skill, item, ...; MAP_UNIT's map
# fields) the first time LCF.elements_of reads it. As bytecode they are some 50 KB of ireps, and compiling them to
# C++ instead would be a size loss (a field is ~265 bytes of code, docs/bc2cpp-vm-entries.md). This generator turns
# them into a byte table in .rodata that one native routine (src/schema_tables.hxx) decodes on demand, so the
# tables stay lazy -- building them all at load raised NoMemoryError on the Wio's 192 KB SRAM -- and no bytecode
# runs for them.
#
# schema.rb stays the single source of truth, plain Ruby that CRuby loads (every scripts/**/*_check.rb does). This
# script `load`s it under CRuby, calls each lambda once, and writes two files for a bc2cpp build:
#
#   schema_folded.rb   schema.rb with each lambda replaced by its table number (same lines, so a backtrace still
#                      names the right line); LCF.elements_of resolves an Integer through LCF.schema_table
#   schema_tables.cc   the tables (lcf_schema_data/_off) and the strings they name (lcf_schema_pool/_pool_off)
#
# A value inside a table that is one of LCF::Schema's own constants (`elements: SE`) is written as a reference to
# that constant, not a copy, so the object sharing the schema relies on is kept. Anything else shared between two
# places raises here rather than silently becoming two objects.
#
# Wire format (all integers are LEB128 varints; signed ones zigzag):
#   value  = tag, payload
#   tag 0 nil, 1 true, 2 false, 3 Integer (zigzag), 4 Float (8 bytes, little endian), 5 Symbol (pool index),
#       6 String (pool index), 7 Array (n, values), 8 Hash (n, key, value, ...), 9 LCF::Schema constant (pool index),
#       12 table: a Hash with Integer keys (n, id, value, ...),
#       11 field: a Hash {name:, type:, [default:], [elements:], [other keys]} in that key order:
#          name (pool index), type (pool index), flags (1 default, 2 elements, 4 other keys),
#          [default value], [elements value], [n, key pool index, value, ...]
# Pool entries 0 to 3 are "name", "type", "default" and "elements".
# The root of every table is a tag-12 value. Order of keys is the order of the source.
require 'prism'
require 'set'

module SchemaTables
  module_function

  NIL = 0
  TRUE = 1
  FALSE = 2
  INT = 3
  FLOAT = 4
  SYM = 5
  STR = 6
  ARRAY = 7
  HASH = 8
  CONST = 9
  FIELD = 11
  TABLE = 12

  # The Prism nodes of the lambdas: a `elements:` value that is `-> { { ... } }`.
  def lambda_nodes(source)
    found = []
    walk = lambda do |node|
      if node.is_a?(Prism::AssocNode) && node.key.is_a?(Prism::SymbolNode) && node.key.unescaped == 'elements' &&
         node.value.is_a?(Prism::LambdaNode)
        body = node.value.body
        ok = body.is_a?(Prism::StatementsNode) && body.body.size == 1 && body.body.first.is_a?(Prism::HashNode)
        raise "schema.rb:#{node.location.start_line}: an `elements:` lambda that is not `-> { { ... } }`" unless ok

        found << node.value
      end
      node.compact_child_nodes.each { |child| walk.call(child) }
    end
    result = Prism.parse(source)
    raise result.errors.map(&:message).join(', ') unless result.errors.empty?

    walk.call(result.value)
    found.sort_by { |n| n.location.start_offset }
  end

  # Loads schema.rb (and lcf.rb before it, as every consumer does) under CRuby and returns [folded source, tables],
  # tables being the Hash each lambda returns, in source order.
  def fold(schema_path, lcf_path)
    source = File.binread(schema_path)
    nodes = lambda_nodes(source)
    load lcf_path
    load schema_path
    procs = {}
    LCF::Schema.constants.each do |name|
      collect_procs(LCF::Schema.const_get(name), procs, Set.new)
    end
    tables = nodes.map do |node|
      line = node.location.start_line
      proc = procs[line] or raise "schema.rb:#{line}: no lambda found at run time"
      proc.call
    end
    raise "#{procs.size} lambdas at run time, #{nodes.size} in the source" unless procs.size == nodes.size

    text = source.dup
    nodes.each_with_index.reverse_each do |node, i|
      loc = node.location
      lines = loc.end_line - loc.start_line
      # The same number of lines: the newlines move behind the number (a comma may follow on the next line).
      text[loc.start_offset...loc.end_offset] = "#{i}#{"\n" * lines}".b
    end
    text << "\n# Folded by mruby-lcf/gen_schema_tables.rb: the `elements:` lambdas are table numbers, " \
            "decoded by LCF.schema_table.\n".b
    [text, tables]
  end

  def collect_procs(value, procs, seen)
    return if seen.include?(value.object_id)

    case value
    when Hash
      seen << value.object_id
      value.each_value { |v| collect_procs(v, procs, seen) }
    when Array
      seen << value.object_id
      value.each { |v| collect_procs(v, procs, seen) }
    when Proc
      line = value.source_location[1]
      raise "two lambdas on schema.rb line #{line}" if procs.key?(line)

      procs[line] = value
    end
  end

  # The strings tables name and the bytes of every table.
  class Encoder
    attr_reader :pool, :tables

    # Pool entries 0..3 are the keys of a field (name, type, default, elements): the decoder takes them by number,
    # because a C string literal "type" in a native source counts as a call of any method called `type`
    # (static_dispatch_registrations.rb, native_name_tokens) and would keep four classes' `type` out of the closed
    # proof.
    FIELD_KEYS = %w[name type default elements].freeze

    def initialize
      @pool = []
      @index = {}
      @tables = []
      @consts = {}
      FIELD_KEYS.each { |k| string(k) }
      LCF::Schema.constants.sort.each do |name|
        value = LCF::Schema.const_get(name)
        # The roots are single field records, not shared tables; only the id => field Hashes are referenced.
        # A table with two names is referenced by the first.
        next unless value.is_a?(Hash) && !value.key?(:type) && !value.empty?

        @consts[value.object_id] ||= name.to_s
      end
    end

    def string(str)
      @index[str.b] ||= begin
        @pool << str.b
        @pool.size - 1
      end
    end

    def varint(num, out)
      loop do
        byte = num & 0x7f
        num >>= 7
        out << (num.zero? ? byte : byte | 0x80)
        break if num.zero?
      end
    end

    def zigzag(num) = num >= 0 ? num << 1 : ((-num) << 1) - 1

    def add_table(hash)
      out = [TABLE]
      varint(hash.size, out)
      hash.each do |id, field|
        raise "table id #{id.inspect}" unless id.is_a?(Integer) && id >= 0

        varint(id, out)
        value(field, out, top: true)
      end
      @tables << out
      @tables.size - 1
    end

    CANONICAL = %i[name type default elements].freeze

    def value(obj, out, top: false)
      case obj
      when nil then out << NIL
      when true then out << TRUE
      when false then out << FALSE
      when Integer
        # The decoder reads 32 bits; a wider number would be a bignum on a 32-bit mrb_int target.
        raise "Integer #{obj} does not fit 32 bits" unless obj.between?(-2**31, 2**31 - 1)

        out << INT
        varint(zigzag(obj), out)
      when Float
        out << FLOAT
        out.concat([obj].pack('E').bytes)
      when Symbol
        out << SYM
        varint(string(obj.to_s), out)
      when String
        out << STR
        varint(string(obj), out)
      when Array
        out << ARRAY
        varint(obj.size, out)
        obj.each { |v| value(v, out) }
      when Hash then hash(obj, out)
      else raise "no encoding for #{obj.class} (#{obj.inspect})"
      end
    end

    def hash(obj, out)
      if (name = @consts[obj.object_id])
        out << CONST
        varint(string(name), out)
        return
      end
      raise 'a Hash shared between two places in a table' if @seen&.include?(obj.object_id)

      (@seen ||= Set.new) << obj.object_id
      if field?(obj)
        field(obj, out)
      elsif obj.keys.all? { |k| k.is_a?(Integer) && k >= 0 } && !obj.empty? && obj.values.all?(Hash)
        out << TABLE
        varint(obj.size, out)
        obj.each do |id, v|
          varint(id, out)
          value(v, out)
        end
      else
        out << HASH
        varint(obj.size, out)
        obj.each do |k, v|
          value(k, out)
          value(v, out)
        end
      end
    end

    # {name: Symbol, type: Symbol, [default:], [elements:], then other Symbol keys}, in that order.
    def field?(obj)
      keys = obj.keys
      return false unless keys.first(2) == %i[name type] && obj[:name].is_a?(Symbol) && obj[:type].is_a?(Symbol)

      rest = keys.drop(2)
      head = CANONICAL.drop(2).select { |k| rest.include?(k) }
      rest.first(head.size) == head && rest.drop(head.size).all? { |k| k.is_a?(Symbol) && !CANONICAL.include?(k) }
    end

    def field(obj, out)
      out << FIELD
      varint(string(obj[:name].to_s), out)
      varint(string(obj[:type].to_s), out)
      others = obj.keys - CANONICAL
      out << ((obj.key?(:default) ? 1 : 0) | (obj.key?(:elements) ? 2 : 0) | (others.empty? ? 0 : 4))
      value(obj[:default], out) if obj.key?(:default)
      value(obj[:elements], out) if obj.key?(:elements)
      return if others.empty?

      varint(others.size, out)
      others.each do |k|
        varint(string(k.to_s), out)
        value(obj[k], out)
      end
    end

    def encode(tables)
      tables.each do |t|
        @seen = Set.new
        add_table(t)
      end
      self
    end
  end

  def cstr(bytes)
    "\"#{bytes.bytes.map { |b| b.between?(0x20, 0x7e) && b != 0x22 && b != 0x5c && b != 0x3f ? b.chr : format('\\%03o', b) }.join}\""
  end

  # The C++ source of the tables.
  def cpp(encoder)
    offsets = [0]
    encoder.tables.each { |t| offsets << offsets.last + t.size }
    pool_offsets = [0]
    encoder.pool.each { |s| pool_offsets << pool_offsets.last + s.bytesize + 1 }
    pool = encoder.pool.map { |s| "#{cstr(s)[0...-1]}\\000\"" }.join("\n    ")
    pool = '""' if pool.empty?
    data = encoder.tables.flatten.each_slice(24).map { |row| "    #{row.join(',')}" }.join(",\n")
    <<~CPP
      // Generated by mruby-lcf/gen_schema_tables.rb from mrblib/schema.rb. Do not edit.
      // #{encoder.tables.size} tables, #{offsets.last} bytes, #{encoder.pool.size} strings.
      extern const char lcf_schema_pool[];
      extern const unsigned lcf_schema_pool_off[];
      extern const unsigned char lcf_schema_data[];
      extern const unsigned lcf_schema_off[];
      extern const unsigned lcf_schema_count;
      const unsigned lcf_schema_count = #{encoder.tables.size};
      const char lcf_schema_pool[] =
          #{pool};
      const unsigned lcf_schema_pool_off[] = {#{pool_offsets.join(', ')}};
      const unsigned lcf_schema_off[] = {#{offsets.join(', ')}};
      const unsigned char lcf_schema_data[] = {
      #{data}};
    CPP
  end

  def generate(schema_path, lcf_path, out_dir)
    text, tables = fold(schema_path, lcf_path)
    encoder = Encoder.new.encode(tables)
    File.binwrite(File.join(out_dir, 'schema_folded.rb'), text)
    File.write(File.join(out_dir, 'schema_tables.cc'), cpp(encoder))
    warn "gen_schema_tables: #{tables.size} tables, #{encoder.tables.sum(&:size)} bytes, #{encoder.pool.size} strings"
    encoder
  end
end

if $PROGRAM_NAME == __FILE__
  schema, lcf, out = ARGV
  abort 'usage: gen_schema_tables.rb mrblib/schema.rb mrblib/lcf.rb OUT_DIR' unless out
  SchemaTables.generate(schema, lcf, out)
end
