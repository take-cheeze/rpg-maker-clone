#!/usr/bin/env ruby
# frozen_string_literal: true

# ROM_SCHEMA: LCF::Schema as constant tables in flash instead of Hashes on the heap.
#
# A compiled build (bc2cpp) reads mrblib_rom/schema.rb instead of mrblib/schema.rb: every Hash of the schema is a node
# of the tables this script writes, and Ruby holds it as its handle, a negative Integer (-1 is node 0). LCF.sget and
# LCF.skeys (lcf.rb) read a handle through the native LCF.rom_get / LCF.rom_keys (src/schema_rom.hxx), and a Hash
# with Hash#[] / #keys, so the readers serve both forms. Nothing else may touch a schema value:
# scripts/bc2cpp-rpg/lcf_schema_rom_check.rb holds the closed world to that.
#
# schema.rb stays the single source of truth. This script `load`s it under CRuby (lcf.rb first, as every consumer
# does), calls each `elements:` lambda once, and numbers every Hash object it reaches once, in the order a walk of
# the constants meets them, so a Hash shared by name (`elements: SE`) or by an alias constant stays one node.
#
#   gen_schema_rom.rb mrblib/schema.rb mrblib/lcf.rb --rb OUT.rb    the handles file (checked in as mrblib_rom/schema.rb)
#   gen_schema_rom.rb mrblib/schema.rb mrblib/lcf.rb --cc OUT.cc    the tables (generated at build time)
#
# Table format (lcf_rom_*): node i owns pairs node_first[i] ... node_first[i + 1] - 1, in source order; a pair is a
# key word and a value word.
#   key   bit 15 clear: the presym id of a Symbol; set: an Integer 0 .. 0x7fff
#   value bit 15 clear: the presym id of a Symbol; set: tag in bits 14-12, operand in bits 11-0
#         tag 0 node, 1 Integer -2048 .. 2047 (two's complement), 2 ext entry, 3 nil (0) / true (1) / false (2)
#   ext   {kind, a, b}: 0 Integer a; 1 String, pool bytes a ... a + b; 2 Float, lcf_rom_doubles[a];
#         3 Array of b value words from lcf_rom_words[a]
# An ext String, Float or Array is a fresh object the first time it is read and the same object after that (a
# Hash held one object), so the native keeps one cache slot per ext entry.
require 'prism'
require 'set'

module SchemaRom
  module_function

  NODE = 0
  SMALL = 1
  EXT = 2
  SPECIAL = 3
  EXT_INT = 0
  EXT_STR = 1
  EXT_FLOAT = 2
  EXT_ARRAY = 3

  # The schema's constants in source order (Module#constants has no fixed order in CRuby).
  def load_schema(schema_path, lcf_path)
    load lcf_path
    load schema_path
    schema_constants(schema_path)
  end

  # LCF::Schema's constants (already loaded) in the order schema.rb assigns them.
  def schema_constants(schema_path)
    names = []
    walk = lambda do |node|
      names << node.name if node.is_a?(Prism::ConstantWriteNode)
      node.compact_child_nodes.each { |child| walk.call(child) }
    end
    walk.call(Prism.parse_file(schema_path).value)
    raise 'schema.rb constants and LCF::Schema.constants differ' unless names.sort == LCF::Schema.constants.sort

    names.to_h { |name| [name, LCF::Schema.const_get(name)] }
  end

  class Encoder
    attr_reader :nodes, :pairs, :ext, :pool, :doubles, :words, :handles

    def initialize
      @nodes = [] # [[key, value]...] per node
      @ids = {} # Hash object_id => node index
      @resolved = {} # Proc object_id => its Hash
      @ext = []
      @pool = +''.b
      @doubles = []
      @words = []
      @shared = {} # String/Array object_id => its ext word, so one object stays one
    end

    # The node of a Hash, numbered on first sight; its pairs are encoded after the number is taken, so a cycle
    # would still terminate (the schema has none).
    def node(hash)
      id = @ids[hash.object_id]
      return id if id

      id = @ids[hash.object_id] = @nodes.size
      raise "more than 4096 schema nodes" if id >= 0x1000

      @nodes << nil
      @nodes[id] = hash.map { |k, v| [key(k), value(v, node_ok: NODE_KEYS.include?(k) || k.is_a?(Integer))] }
      id
    end

    # The keys whose value may be a schema Hash. The readers know a node by where it is (an `elements:` value, a
    # table's field), never by its class, so a Hash anywhere else (a `default:`) would reach Ruby as a bare Integer.
    NODE_KEYS = %i[elements enums].freeze

    def key(obj)
      case obj
      when Symbol then [:sym, obj]
      when Integer
        raise "schema key #{obj} outside 0 .. 0x7fff" unless obj.between?(0, 0x7fff)

        [:int, obj]
      else raise "schema key #{obj.inspect}: only Symbols and Integers"
      end
    end

    def value(obj, node_ok: false)
      raise "a schema Hash as a value other than `elements:`, `enums:` or a table field" if obj.is_a?(Hash) && !node_ok

      case obj
      when Symbol then [:sym, obj]
      when nil then [:word, 0x8000 | (SPECIAL << 12) | 0]
      when true then [:word, 0x8000 | (SPECIAL << 12) | 1]
      when false then [:word, 0x8000 | (SPECIAL << 12) | 2]
      when Integer
        return [:word, 0x8000 | (SMALL << 12) | (obj & 0xfff)] if obj.between?(-2048, 2047)
        # A wider number would be a bignum on a 32-bit mrb_int target.
        raise "Integer #{obj} does not fit 32 bits" unless obj.between?(-2**31, 2**31 - 1)

        ext_word(EXT_INT, obj, 0)
      when Float
        @doubles << obj
        ext_word(EXT_FLOAT, @doubles.size - 1, 0)
      when String
        return @shared[obj.object_id] if @shared.key?(obj.object_id)

        at = @pool.bytesize
        @pool << obj.b
        @shared[obj.object_id] = ext_word(EXT_STR, at, obj.bytesize)
      when Array
        return @shared[obj.object_id] if @shared.key?(obj.object_id)

        # Encoded before the entry is taken, so a nested Array's words come first and this one's stay contiguous.
        elems = obj.map { |v| leaf_word(v) }
        at = @words.size
        @words.concat(elems)
        @shared[obj.object_id] = ext_word(EXT_ARRAY, at, elems.size)
      when Proc
        raise 'a lambda other than `elements: -> { {...} }`' unless node_ok

        value(@resolved[obj.object_id] ||= obj.call, node_ok: true)
      when Hash then [:word, 0x8000 | (NODE << 12) | node(obj)]
      else raise "no ROM encoding for #{obj.class} (#{obj.inspect})"
      end
    end

    # A value inside an Array is materialised with the Array, so it may not be a node (a handle would leak into
    # the Array as a plain Integer).
    def leaf_word(obj)
      raise "a schema Hash inside an Array value" if obj.is_a?(Hash) || obj.is_a?(Proc)

      value(obj)
    end

    def ext_word(kind, a, b)
      raise "more than 4096 ext entries" if @ext.size >= 0x1000

      @ext << [kind, a, b]
      [:word, 0x8000 | (EXT << 12) | (@ext.size - 1)]
    end

    # Ruby source of each constant: a handle for a Hash, an Array of handles for MAP_TREE, an Integer as written.
    def constant_source(obj)
      case obj
      when Hash then "-#{node(obj) + 1}"
      when Array
        raise 'a constant Array holds only schema Hashes' unless obj.all?(Hash)

        "[#{obj.map { |h| "-#{node(h) + 1}" }.join(', ')}]"
      when Integer then obj.to_s
      else raise "constant of class #{obj.class}"
      end
    end

    # A table (an `elements:` value, or a constant that is no field) holds only fields, and an `elements:` value is a
    # table or nil: LCF.elements_of tells a handle from a value by that alone.
    def check_tables(constants)
      tables = constants.values.select { |v| v.is_a?(Hash) && !v.key?(:type) }
      seen = Set.new
      walk = lambda do |h|
        next unless seen.add?(h.object_id)

        e = h[:elements]
        e = @resolved[e.object_id] ||= e.call if e.is_a?(Proc)
        raise "`elements:` is a #{e.class}, not a table" unless e.nil? || e.is_a?(Hash)

        tables << e if e
        h.each_value { |v| walk.call(v) if v.is_a?(Hash) }
      end
      constants.each_value { |v| (v.is_a?(Array) ? v : [v]).each { |x| walk.call(x) if x.is_a?(Hash) } }
      tables.each do |t|
        raise 'a schema table with a value that is not a field Hash' unless t.all? { |k, v| k.is_a?(Integer) && v.is_a?(Hash) }
      end
    end

    def encode(constants)
      check_tables(constants)
      @handles = constants.to_h { |name, obj| [name, constant_source(obj)] }
      self
    end
  end

  def cword(word)
    kind, v = word
    case kind
    when :sym then "MRB_SYM(#{v})"
    when :int then format('0x%04x', 0x8000 | v)
    when :word then format('0x%04x', v)
    end
  end

  def symbol_name!(sym)
    raise "schema Symbol :#{sym} has no MRB_SYM spelling" unless sym.to_s.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
  end

  def cstr(bytes)
    body = bytes.bytes.map { |b| b.between?(0x20, 0x7e) && b != 0x22 && b != 0x5c && b != 0x3f ? b.chr : format('\\%03o', b) }
    "\"#{body.join}\""
  end

  def cpp(enc)
    first = [0]
    words = []
    enc.nodes.each do |pairs|
      pairs.each do |k, v|
        [k, v].each { |w| symbol_name!(w[1]) if w[0] == :sym }
        words << cword(k) << cword(v)
      end
      first << first.last + pairs.size
    end
    raise 'more than 0xffff schema pairs' if first.last > 0xffff

    enc.words.each { |w| symbol_name!(w[1]) if w[0] == :sym }
    rows = ->(list) { list.empty? ? '0' : list.each_slice(8).map { |r| "    #{r.join(', ')}" }.join(",\n") }
    ext = enc.ext.map { |kind, a, b| "{#{kind}, #{a}, #{b}}" }
    doubles = enc.doubles.map { |d| d.to_s }
    <<~CPP
      // Generated by mruby-lcf/gen_schema_rom.rb from mrblib/schema.rb. Do not edit.
      // #{enc.nodes.size} nodes, #{first.last} pairs, #{enc.ext.size} ext entries.
      #include <mruby.h>
      #include <mruby/presym.h>
      #include "schema_rom.hxx"

      static_assert(MRB_PRESYM_MAX < 0x8000, "a ROM schema word holds a presym id in 15 bits");

      const unsigned lcf_rom_node_count = #{enc.nodes.size};
      const unsigned lcf_rom_ext_count = #{enc.ext.size};
      const uint16_t lcf_rom_node_first[] = {
      #{rows.call(first)}};
      const uint16_t lcf_rom_pairs[] = {
      #{rows.call(words)}};
      const lcf_rom_ext_entry lcf_rom_ext[] = {
      #{rows.call(ext)}};
      const uint16_t lcf_rom_words[] = {
      #{rows.call(enc.words.map { |w| cword(w) })}};
      const double lcf_rom_doubles[] = {#{doubles.empty? ? '0' : doubles.join(', ')}};
      const char lcf_rom_pool[] = #{cstr(enc.pool)};
    CPP
  end

  def ruby(enc, schema_digest)
    consts = enc.handles.map { |name, src| "    #{name} = #{src}" }.join("\n")
    <<~RUBY
      # Generated by mruby-lcf/gen_schema_rom.rb from mrblib/schema.rb (SHA256 #{schema_digest}). Do not edit:
      # regenerate with `ruby mruby-lcf/gen_schema_rom.rb mruby-lcf/mrblib/schema.rb mruby-lcf/mrblib/lcf.rb --rb mruby-lcf/mrblib_rom/schema.rb`.
      #
      # The schema of a compiled build: each table is the handle of its node in the ROM tables (a negative Integer),
      # read through LCF.sget / LCF.skeys. See gen_schema_rom.rb.
      module LCF
        module Schema
      #{consts}
        end
      end
    RUBY
  end

  def encoder(schema_path, lcf_path)
    Encoder.new.encode(load_schema(schema_path, lcf_path))
  end

  def generate(schema_path, lcf_path, mode, out)
    require 'digest'
    enc = encoder(schema_path, lcf_path)
    text = mode == '--rb' ? ruby(enc, Digest::SHA256.file(schema_path).hexdigest) : cpp(enc)
    File.write(out, text)
    enc
  end
end

if $PROGRAM_NAME == __FILE__
  schema, lcf, mode, out = ARGV
  abort 'usage: gen_schema_rom.rb mrblib/schema.rb mrblib/lcf.rb --rb|--cc OUT' unless out && %w[--rb --cc].include?(mode)
  SchemaRom.generate(schema, lcf, mode, out)
end
