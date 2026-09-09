#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates mrblib/schema.rb's runtime replacement: a compact packed binary
# blob plus a small, constant-size decoder, instead of ~1,150 field
# descriptors each compiled to their own Hash-literal-construction bytecode
# (mrbc measured: 45,293 bytes for schema.rb alone -- see docs/adr/0109).
#
# schema.rb (this generator's *input*, never modified) stays the single
# source of truth: it is plain, portable Ruby, loadable by CRuby (every
# check script in scripts/ does exactly that) with no dependency on this
# generator or its output. This script `load`s it once, under CRuby, and
# walks LCF::Schema's constants, then serializes the *resolved field data*
# (not the Ruby source) into a compact binary table plus the string table
# field/order names draw from.
#
# ADR 0099's own NoMemoryError finding (schema.rb's own `lazy` comment)
# governs the split this generator preserves exactly: DATABASE's ~18
# per-record-type field lists (each a `-> { {...} }` block in the source)
# stay lazily resolved -- decoded from the blob into real Hash objects only
# on first LCF.elements_of access, cached from then on -- while everything
# schema.rb itself already built eagerly (COMMON_EVENT, BGM, SE, ...) is
# decoded eagerly here too, at the exact same point (module load). This
# generator only changes the *storage representation* (packed bytes plus a
# shared decoder loop, instead of one Hash-literal bytecode sequence per
# field); it does not move anything across that laziness boundary.
#
# Wire format (all integers little-endian). Order matters: SECTIONS must
# come before TOP-LEVEL so a kind-2 top-level entry (DATABASE/SAVE_DATA/
# MAP_UNIT) can eagerly decode a non-lazy nested section -- see the
# `:field` case in Generator#generate and Blob.parse! below -- while it is
# itself still being read, without a second pass.
#   STRING TABLE:  u16 count; count * (u8 len, len bytes)
#   OFFSET TABLE:  u16 section_count; section_count * u16 (byte offset,
#                  relative to the start of the SECTIONS region below);
#                  u32 total byte size of the SECTIONS region (lets the
#                  decoder skip straight past it to the TOP-LEVEL table
#                  that follows, without parsing every section eagerly)
#   SECTIONS:      one per offset-table entry, back to back:
#                  u16 entry_count; entry_count * ENTRY
#   TOP-LEVEL:     u16 count; count * (u16 name_idx, u8 kind, ...)
#                  kind 0 (eager section) / 1 (lazy section) / 3 (array of
#                  field records, MAP_TREE only): u16 section_idx
#                  kind 2 (a single field record used directly as a whole
#                  file's root schema -- DATABASE/SAVE_DATA/MAP_UNIT): the
#                  field body inline (see ENTRY below, minus the id)
#   ENTRY:         u16 id, then the field body:
#                    u16 name_idx, u8 type_tag, u8 flags, u8 default_tag,
#                    [i16 default_value if default_tag == DEFAULT_INT],
#                    [u8 order_count, order_count * u16 name_idx if flags&1],
#                    [u16 nested_section_idx if flags&2]
#                  flags: bit0 has_order, bit1 has_nested, bit2 nested_lazy
#
# Usage: ruby gen_schema_blob.rb <path-to-mrblib/schema.rb> <output.rb>

SCHEMA_PATH = ARGV.fetch(0)
OUT_PATH = ARGV.fetch(1)

# Loading schema.rb needs the LCF.level_max / LCF.exp_default helpers a few
# defaults call (real module_functions in lcf.rb, alongside schema.rb);
# Schema.lazy itself is defined in schema.rb.
load ::File.join(::File.dirname(SCHEMA_PATH), 'lcf.rb')
load SCHEMA_PATH

TYPE_TAGS = {
  int: 1, string: 2, bool: 3, Array1D: 4, Array2D: 5, int8_array: 6,
  double: 7, int16_array: 8, uint8: 9, int32_array: 10, event: 11,
  move_commands: 12, bool_array: 13, Tree: 14,
}.freeze

DEFAULT_NIL = 0
DEFAULT_INT = 1
DEFAULT_EMPTY_STRING = 2
DEFAULT_FALSE = 3
DEFAULT_TRUE = 4
DEFAULT_EMPTY_ARRAY = 5
DEFAULT_FLOAT_0 = 6
DEFAULT_FLOAT_100 = 7
DEFAULT_PROC_LEVEL_MAX = 8
DEFAULT_PROC_EXP_DEFAULT = 9

class BlobWriter
  def initialize
    @buf = +''.b
  end

  def u8(v)
    raise "u8 overflow: #{v}" if v > 0xff || v.negative?
    @buf << [v].pack('C')
    self
  end

  def u16(v)
    raise "u16 overflow: #{v}" if v > 0xffff || v.negative?
    @buf << [v].pack('v')
    self
  end

  def i16(v)
    raise "i16 overflow: #{v}" if v > 32_767 || v < -32_768
    @buf << [v].pack('s<')
    self
  end

  def u32(v)
    raise "u32 overflow: #{v}" if v > 0xffff_ffff || v.negative?
    @buf << [v].pack('V')
    self
  end

  def bytes(s)
    @buf << s
    self
  end

  def size = @buf.bytesize
  def to_s = @buf
end

class Generator
  def initialize
    @strings = []
    @string_idx = {}
    @sections = [] # each entry: raw bytes for one section (entry_count + entries)
    @section_idx_by_object_id = {}
  end

  def string_index(sym_or_str)
    s = sym_or_str.to_s
    @string_idx[s] ||= begin
      @strings << s
      @strings.size - 1
    end
  end

  def default_tag_and_value(d)
    case d
    when nil then [DEFAULT_NIL, nil]
    when Integer then [DEFAULT_INT, d]
    when String
      raise "unsupported non-empty string default: #{d.inspect}" unless d.empty?
      [DEFAULT_EMPTY_STRING, nil]
    when true then [DEFAULT_TRUE, nil]
    when false then [DEFAULT_FALSE, nil]
    when Array
      raise "unsupported non-empty array default: #{d.inspect}" unless d.empty?
      [DEFAULT_EMPTY_ARRAY, nil]
    when Float
      case d
      when 0.0 then [DEFAULT_FLOAT_0, nil]
      when 100.0 then [DEFAULT_FLOAT_100, nil]
      else raise "unsupported float default: #{d.inspect}"
      end
    else
      raise "unsupported default kind: #{d.inspect}" unless d.respond_to?(:call)

      # Only two callable defaults exist anywhere in schema.rb (grep
      # confirms: `default: ->` appears six times total, one LCF.level_max
      # and five LCF.exp_default) -- identify by source text so a future
      # third callable raises loudly here instead of being silently
      # mis-tagged.
      loc = d.source_location
      src = loc && ::File.readlines(loc.first)[loc.last - 1]
      if src&.include?('LCF.level_max')
        [DEFAULT_PROC_LEVEL_MAX, nil]
      elsif src&.include?('LCF.exp_default')
        [DEFAULT_PROC_EXP_DEFAULT, nil]
      else
        raise "unrecognized callable default (add a DEFAULT_PROC_* case): #{src.inspect}"
      end
    end
  end

  # Encode one field record's body (everything but the `id` a section
  # stores it under -- a top-level FIELD constant like DATABASE has no id).
  def encode_field_body(w, field)
    name_idx = string_index(field.fetch(:name))
    type_tag = TYPE_TAGS.fetch(field.fetch(:type)) { raise "unknown type: #{field[:type]}" }
    has_order = field.key?(:order)
    nested = field[:elements]
    has_nested = !nested.nil?
    nested_lazy = has_nested && nested.respond_to?(:call)
    flags = (has_order ? 1 : 0) | (has_nested ? 2 : 0) | (nested_lazy ? 4 : 0)
    dtag, dval = default_tag_and_value(field[:default])

    w.u16(name_idx).u8(type_tag).u8(flags).u8(dtag)
    w.i16(dval) if dtag == DEFAULT_INT
    if has_order
      names = field[:order]
      w.u8(names.size)
      names.each { |n| w.u16(string_index(n)) }
    end
    return unless has_nested

    resolved = nested_lazy ? nested.call : nested
    w.u16(section_index(resolved))
  end

  # A "section" is a plain id => field Hash (COMMON_EVENT, BGM, ..., and
  # every DATABASE/MAP_*'s per-record `elements:` value once resolved).
  # Memoized by object identity -- this preserves the *shared-object* reuse
  # several fields rely on (`elements: SE` appears at more than one call
  # site, pointing at the exact same Hash): two references to the same
  # original Hash become one section, not two duplicated copies, the same
  # sharing schema.rb's own `elements_of` comment describes relying on.
  def section_index(hash)
    key = hash.object_id
    return @section_idx_by_object_id[key] if @section_idx_by_object_id.key?(key)

    idx = @sections.size
    @sections << nil # reserve the slot before recursing
    @section_idx_by_object_id[key] = idx

    w = BlobWriter.new
    entries = hash.sort_by { |id, _| id }
    w.u16(entries.size)
    entries.each do |id, field|
      raise "section entry id out of range: #{id}" unless id.is_a?(Integer) && id >= 0 && id <= 0xffff

      w.u16(id)
      encode_field_body(w, field)
    end
    @sections[idx] = w.to_s
    idx
  end

  def generate
    top_entries = []

    LCF::Schema.constants.sort.each do |cname|
      val = LCF::Schema.const_get(cname)
      next if val.is_a?(Integer) # SCROLL_UNITS_PER_PIXEL: not schema data

      string_index(cname)
      if val.is_a?(Array)
        # MAP_TREE: an ordered list of FIELD records (a multi-section
        # file's root schemas), not an id-keyed section -- encode as a
        # section keyed 0..n-1 so it reuses the entry/field machinery,
        # reconstructed back into an Array on the way out.
        fields_as_section = {}
        val.each_with_index { |f, i| fields_as_section[i] = f }
        top_entries << [cname, :array, section_index(fields_as_section)]
      elsif val.respond_to?(:call)
        top_entries << [cname, :lazy_section, section_index(val.call)]
      elsif val.key?(:name) && val.key?(:type)
        # DATABASE / SAVE_DATA / MAP_UNIT: a single field record used
        # directly as a whole file's root schema (LCF::File#schema).
        # Encoded to bytes right here, once: DATABASE's own per-record
        # `elements:` procs are bare `-> { {...} }` blocks, not `lazy{}`
        # (only *top-level* constants get that memoizing wrapper -- see
        # schema.rb's own Schema.lazy definition), so calling one a second
        # time (e.g. by
        # re-running encode_field_body against a throwaway writer first and
        # "for real" later) returns a *different* Hash object each time --
        # section_index, keyed by object_id, would then register it twice.
        field_w = BlobWriter.new
        encode_field_body(field_w, val)
        top_entries << [cname, :field, field_w.to_s]
      else
        top_entries << [cname, :eager_section, section_index(val)]
      end
    end

    strings_w = BlobWriter.new
    strings_w.u16(@strings.size)
    @strings.each do |s|
      raise "string too long: #{s.inspect}" if s.bytesize > 255

      strings_w.u8(s.bytesize).bytes(s)
    end

    section_offsets = []
    running = 0
    @sections.each do |bytes|
      section_offsets << running
      running += bytes.bytesize
    end
    sections_blob = @sections.join
    offsets_w = BlobWriter.new
    offsets_w.u16(@sections.size)
    section_offsets.each { |o| offsets_w.u16(o) }
    offsets_w.u32(sections_blob.bytesize)

    top_w = BlobWriter.new
    top_w.u16(top_entries.size)
    top_entries.each do |cname, kind, payload|
      top_w.u16(string_index(cname))
      case kind
      when :eager_section then top_w.u8(0).u16(payload)
      when :lazy_section then top_w.u8(1).u16(payload)
      when :field
        top_w.u8(2).bytes(payload)
      when :array then top_w.u8(3).u16(payload)
      end
    end
    raise 'internal error: a new string appeared after the string table was sealed' \
      if @strings.size != strings_w.to_s.unpack1('v')
    raise 'internal error: a new section appeared after offsets were sealed' \
      if @sections.size != offsets_w.to_s.unpack1('v')

    blob = strings_w.to_s + offsets_w.to_s + sections_blob + top_w.to_s
    [blob, top_entries.size, @sections.size, @strings.size]
  end
end

gen = Generator.new
blob, top_count, section_count, string_count = gen.generate

warn "gen_schema_blob: #{blob.bytesize} bytes " \
     "(#{top_count} top-level constants, #{section_count} sections, " \
     "#{string_count} strings)"

DECODER = <<~'RUBY'
  module LCF
    module Schema
      # Decoder for the packed BLOB above -- see gen_schema_blob.rb's own
      # header comment for the wire format and docs/adr/0109 for why this
      # exists. Plain, portable Ruby (mruby- and CRuby-compatible): no
      # native code, no StringIO, just integer-indexed String#getbyte /
      # #byteslice reads, so this costs the same small, constant amount of
      # bytecode no matter how many fields BLOB itself describes. Never
      # hand-edit BLOB or this module -- regenerate both from mrblib/
      # schema.rb via gen_schema_blob.rb instead.
      module Blob
        TYPES = {
          1 => :int, 2 => :string, 3 => :bool, 4 => :Array1D, 5 => :Array2D,
          6 => :int8_array, 7 => :double, 8 => :int16_array, 9 => :uint8,
          10 => :int32_array, 11 => :event, 12 => :move_commands,
          13 => :bool_array, 14 => :Tree,
        }.freeze

        class Reader
          def initialize(s, pos = 0)
            @s = s
            @pos = pos
          end

          attr_reader :pos

          def u8
            v = @s.getbyte(@pos)
            @pos += 1
            v
          end

          def u16
            lo = u8
            hi = u8
            lo | (hi << 8)
          end

          def i16
            v = u16
            v >= 0x8000 ? v - 0x10000 : v
          end

          def u32
            lo = u16
            hi = u16
            lo | (hi << 16)
          end

          def bytes(n)
            v = @s.byteslice(@pos, n)
            @pos += n
            v
          end

          def skip(n)
            @pos += n
          end
        end

        def self.decode_default(r, tag)
          case tag
          when 0 then nil
          when 1 then r.i16
          when 2 then ''
          when 3 then false
          when 4 then true
          when 5 then []
          when 6 then 0.0
          when 7 then 100.0
          when 8 then -> { LCF.level_max }
          when 9 then -> { LCF.exp_default }
          else raise "bad default tag: #{tag}"
          end
        end

        def self.decode_field_body(r)
          name = @symbols[r.u16]
          type = TYPES.fetch(r.u8)
          flags = r.u8
          dtag = r.u8
          d = decode_default(r, dtag)
          h = { name: name, type: type }
          h[:default] = d unless dtag == 0
          if (flags & 1) != 0
            count = r.u8
            h[:order] = Array.new(count) { @symbols[r.u16] }
          end
          if (flags & 2) != 0
            idx = r.u16
            h[:elements] = (flags & 4) != 0 ? -> { section(idx) } : section(idx)
          end
          h
        end

        def self.parse!
          return if @parsed
          @parsed = true

          r = Reader.new(BLOB)
          str_count = r.u16
          @symbols = Array.new(str_count) { r.bytes(r.u8).to_sym }

          sec_count = r.u16
          @section_offsets = Array.new(sec_count) { r.u16 }
          sections_byte_size = r.u32
          # SECTIONS come right after this header (see gen_schema_blob.rb's
          # own Generator#generate: strings, offsets, sections_byte_size,
          # sections, *then* the top-level table) so @sections_region_start
          # is already valid before the top-level table below is read --
          # decode_field_body can eagerly call section() for a non-lazy
          # nested field (e.g. DATABASE's own outer `elements:`) while
          # parsing a kind-2 top-level entry, and that needs it set.
          @sections_region_start = r.pos
          @section_cache = {}
          r.skip(sections_byte_size) # jump straight to the top-level table

          top_count = r.u16
          @top = {}
          top_count.times do
            name = @symbols[r.u16]
            kind = r.u8
            @top[name] =
              case kind
              when 0, 1, 3 then [kind, r.u16]
              when 2 then [kind, decode_field_body(r)]
              end
          end
        end
        # No private_class_method here: mruby's default gem set does not
        # implement it (confirmed by actually running this file through a
        # real mruby interpreter -- "undefined method 'private_class_method'
        # for Module"), and it buys nothing real anyway -- nothing outside
        # this module ever calls parse! directly.

        def self.section(idx)
          parse!
          @section_cache[idx] ||= begin
            r = Reader.new(BLOB, @sections_region_start + @section_offsets[idx])
            count = r.u16
            h = {}
            count.times do
              id = r.u16
              h[id] = decode_field_body(r)
            end
            h
          end
        end

        def self.top(name)
          parse!
          kind, payload = @top[name]
          case kind
          when 0 then section(payload)
          when 1 then -> { section(payload) }
          when 2 then payload
          when 3
            h = section(payload)
            h.keys.sort.map { |k| h[k] }
          end
        end
      end
    end
  end
RUBY

top_names = LCF::Schema.constants.sort.reject { |c| LCF::Schema.const_get(c).is_a?(Integer) }

::File.open(OUT_PATH, 'wb') do |f|
  f.write "# Generated by mruby-lcf/gen_schema_blob.rb from mrblib/schema.rb.\n"
  f.write "# Do not hand-edit -- regenerate instead. See docs/adr/0109.\n"
  f.write "module LCF\n  module Schema\n"
  # No `.b` here: mruby strings have no per-object encoding tag to begin
  # with (raw bytes already), and mruby-string-ext -- unlike CRuby -- does
  # not implement String#b at all, so calling it aborts the real mruby
  # build outright ("undefined method 'b' for String"), confirmed by
  # actually running this generated file through a real mruby interpreter,
  # not just the CRuby-side comparison script.
  f.write "    BLOB = #{blob.inspect}\n"
  f.write "  end\nend\n\n"
  f.write DECODER
  f.write "\n"
  f.write "module LCF\n  module Schema\n"
  f.write "    SCROLL_UNITS_PER_PIXEL = #{LCF::Schema::SCROLL_UNITS_PER_PIXEL}\n"
  top_names.each { |cname| f.write "    #{cname} = Blob.top(:#{cname})\n" }
  f.write "  end\nend\n"
end

warn "gen_schema_blob: wrote #{OUT_PATH}"
