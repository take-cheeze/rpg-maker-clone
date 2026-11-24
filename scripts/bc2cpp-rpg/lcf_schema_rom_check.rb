#!/usr/bin/env ruby
# frozen_string_literal: true

# ROM_SCHEMA (mruby-lcf/gen_schema_rom.rb, mruby-lcf/src/schema_rom.hxx): a compiled build holds LCF::Schema as
# constant tables and Ruby holds each Hash of it as a handle, so the tables must answer exactly what the Hashes did,
# and nothing but the readers may see a handle.
#
#   handles  mruby-lcf/mrblib_rom/schema.rb is what the generator writes from schema.rb today
#   tables   a Ruby reading of the generated C++ tables gives every constant of schema.rb back (lambdas called): the
#            same keys in the same order, the same values, one node per Hash object and one entry per String/Array
#   readers  under CRuby, LCF's readers give the same answers over handles (LCF.rom_get/rom_keys answered from the
#            tables) as over the Hashes: every field of every table read absent, its name lookup, and a write and
#            read back of every field that has a default
#   native   schema_rom.hxx built with a full-core libmruby walks the tables to the same text, with a full collection
#            before every String/Array it makes; a String is the same mutable object on every read; a key no Hash
#            holds, of any class, is nil; a value that is no handle raises
#   closure  in the closed world, a schema value is made and read only by the reviewed readers (READERS): a schema
#            constant is only read where it is handed to Array1D/Array2D.new or returned by a File#schema, and
#            `schema`, `elements_of`, `sget`, `skeys`, `rom_get`, `rom_keys` and `@schema` appear nowhere else. The
#            readers' source is pinned: a change to one is reviewed against this file and the pin moved.
#   switch   tools/bc2cpp/compiled_gems.rb compiles mrblib_rom/schema.rb in place of schema.rb, and schema.rb
#            under BC2CPP_ROM_SCHEMA=0
#
# Needs a full-core libmruby for the native half (BC2CPP_MRUBY_FULL or BC2CPP_FULL_BUILD_DIR).
ENV['BC2CPP_SIG_DIRS'] = ''

require_relative '../../tools/bc2cpp/world_root'
require 'digest'
require 'open3'
require 'prism'
require 'set'
require 'stringio'
require 'tmpdir'
require_relative '../bc2cpp/check_support'
require_relative '../bc2cpp/fixture_runtime'
require File.join(BC2CPP_WORLD_ROOT, 'mruby-lcf/gen_schema_rom')

suite = FixtureCheck.new('lcf_schema_rom_check')
ROOT_DIR = BC2CPP_WORLD_ROOT
SCHEMA = "#{ROOT_DIR}/mruby-lcf/mrblib/schema.rb"
LCF_RB = "#{ROOT_DIR}/mruby-lcf/mrblib/lcf.rb"
HANDLES = "#{ROOT_DIR}/mruby-lcf/mrblib_rom/schema.rb"

# The Ruby reading of the generated tables: the C++ text parsed back into words.
class RomTables
  attr_reader :first, :pairs, :ext, :words, :doubles, :pool

  def initialize(cpp)
    @first = ints(array(cpp, 'lcf_rom_node_first'))
    @pairs = array(cpp, 'lcf_rom_pairs').map { |t| word(t) }
    @ext = array(cpp, 'lcf_rom_ext', braces: true).map { |t| t.scan(/\d+/).map(&:to_i) }
    @words = array(cpp, 'lcf_rom_words').map { |t| word(t) }
    @doubles = cpp[/lcf_rom_doubles\[\] = \{([^}]*)\}/, 1].split(',').map(&:to_f)
    lit = cpp[/lcf_rom_pool\[\] = "((?:[^"\\]|\\.)*)";/, 1]
    @pool = lit.gsub(/\\([0-7]{3})/) { Regexp.last_match(1).to_i(8).chr }.b
    @slots = {}
  end

  def array(cpp, name, braces: false)
    body = cpp[/#{name}\[\] = \{\n(.*?)\};/m, 1] or raise "no #{name}"
    braces ? body.scan(/\{[^}]*\}/) : body.split(',').map(&:strip).reject(&:empty?)
  end

  def ints(list) = list.map { |t| Integer(t) }

  # A Symbol word as its name, any other as the Integer.
  def word(token)
    token =~ /\AMRB_SYM\((\w+)\)\z/ ? Regexp.last_match(1).to_sym : Integer(token)
  end

  def node_count = @first.size - 1

  def node_index(handle)
    raise TypeError, "schema node handle is #{handle.class}, not Integer" unless handle.is_a?(Integer)
    raise IndexError, "no schema node #{handle}" unless handle.negative? && -(handle + 1) < node_count

    -(handle + 1)
  end

  def value(w)
    return w if w.is_a?(Symbol)

    op = w & 0xfff
    case (w >> 12) & 7
    when 0 then -op - 1
    when 1 then op & 0x800 != 0 ? op - 0x1000 : op
    when 2 then ext_value(op)
    else [nil, true, false].fetch(op)
    end
  end

  def ext_value(i)
    kind, a, b = @ext.fetch(i)
    return a >= 0x8000_0000 ? a - 0x1_0000_0000 : a if kind.zero?

    @slots[i] ||= case kind
                  when 1 then @pool.byteslice(a, b).dup.force_encoding('UTF-8')
                  when 2 then @doubles.fetch(a)
                  else Array.new(b) { |k| value(@words.fetch(a + k)) }
                  end
  end

  def key_word(key)
    case key
    when Symbol then key
    when Integer then key.between?(0, 0x7fff) ? 0x8000 | key : nil
    end
  end

  def get(handle, key)
    n = node_index(handle)
    k = key_word(key)
    return nil if k.nil?

    (@first[n]...@first[n + 1]).each { |p| return value(@pairs[2 * p + 1]) if @pairs[2 * p] == k }
    nil
  end

  def keys(handle)
    n = node_index(handle)
    (@first[n]...@first[n + 1]).map { |p| (k = @pairs[2 * p]).is_a?(Symbol) ? k : k & 0x7fff }
  end
end

# The text of a schema value: a node is printed whole on its first visit (#n) and as @n after, so two dumps agree
# only if the same objects are shared. A ROM node is told by where it is (gen_schema_rom.rb, NODE_KEYS / tables).
class SchemaDump
  def initialize(rom: nil)
    @rom = rom
    @marks = {}
  end

  def mark(identity)
    if (n = @marks[identity])
      return "@#{n}", false
    end

    @marks[identity] = @marks.size
    ["##{@marks.size - 1}", true]
  end

  def node(v)
    return 'nil' if v.nil?

    if @rom
      tag, fresh = mark([:node, v])
      return tag unless fresh

      pairs = @rom.keys(v).map { |k| [k, @rom.get(v, k)] }
    else
      v = v.call while v.is_a?(Proc)
      tag, fresh = mark([:node, v.object_id])
      return tag unless fresh

      pairs = v.to_a
    end
    "#{tag}{#{pairs.map { |k, x| "#{scalar(k)}=>#{node_key?(k) && !scalar_value?(x) ? node(x) : leaf(x)}" }.join(',')}}"
  end

  def node_key?(k) = k.is_a?(Integer) || %i[elements enums].include?(k)

  # Under an Integer key of `enums:` the value is a Symbol, not a node.
  def scalar_value?(x) = x.is_a?(Symbol) || x.nil?

  def leaf(x)
    case x
    when String, Array
      tag, fresh = mark([:leaf, x.object_id])
      return tag unless fresh

      x.is_a?(String) ? "#{tag}S(#{x.bytes.join(' ')})" : "#{tag}[#{x.map { |e| leaf(e) }.join(',')}]"
    when Proc then node(x)
    else scalar(x)
    end
  end

  def scalar(x)
    case x
    when Symbol then ":#{x}"
    when Integer then "I#{x}"
    when Float then "F#{x}"
    when nil, true, false then x.inspect
    else raise "dump: #{x.class}"
    end
  end

  # `kind`: the class of the constant in schema.rb (a ROM build holds a Hash as an Integer).
  def constant(v, kind)
    return "[#{v.map { |x| node(x) }.join(',')}]" if kind == Array

    kind == Hash ? node(v) : scalar(v)
  end
end

def dump_constants(consts, kinds, rom: nil)
  d = SchemaDump.new(rom: rom)
  consts.map { |name, v| "#{name} #{d.constant(v, kinds.fetch(name))}" }.join("\n")
end

Dir.mktmpdir('lcf-schema-rom') do |dir|
  # --- handles -------------------------------------------------------------------------------------------
  fresh_rb = File.join(dir, 'handles.rb')
  cc = File.join(dir, 'schema_rom.cc')
  enc = SchemaRom.encoder(SCHEMA, LCF_RB)
  File.write(fresh_rb, SchemaRom.ruby(enc, Digest::SHA256.file(SCHEMA).hexdigest))
  File.write(cc, SchemaRom.cpp(enc))
  suite.check('mrblib_rom/schema.rb is the generator\'s output for today\'s schema.rb',
              File.exist?(HANDLES) && File.binread(HANDLES) == File.binread(fresh_rb))
  # SchemaRom.encoder loaded lcf.rb and schema.rb: the Hashes.
  hash_consts = SchemaRom.schema_constants(SCHEMA)
  hash_lcf_constants = LCF::Schema.constants.sort

  # --- tables --------------------------------------------------------------------------------------------
  rom = RomTables.new(File.read(cc))
  rom_consts = File.read(HANDLES).scan(/^    ([A-Z][A-Z0-9_]*) = (.+)$/).to_h do |name, rhs|
    [name.to_sym, rhs.start_with?('[') ? rhs.delete('[]').split(',').map { |x| Integer(x) } : Integer(rhs)]
  end
  consts = rom_consts.keys
  suite.check('the handles file names every constant of schema.rb, in its order',
              consts == hash_consts.keys && consts.sort == hash_lcf_constants)
  kinds = hash_consts.transform_values(&:class)
  want = dump_constants(hash_consts, kinds)
  got = dump_constants(rom_consts, kinds, rom: rom)
  if got != want
    a = got.lines
    b = want.lines
    i = a.zip(b).index { |x, y| x != y }
    puts "    first difference at line #{i}:", "      rom:  #{a[i].to_s[0, 300]}", "      hash: #{b[i].to_s[0, 300]}" if i
  end
  suite.check('the tables read back as schema.rb: keys in order, values, and every shared object', got == want)
  suite.check('the dump covers every node (1,000+)', want.scan(/#\d+\{/).size == enc.nodes.size && enc.nodes.size > 1000)
  suite.check('an alias constant is the same node (SAVE_FOREGROUND_EVENT is SAVE_EVENT_EXEC_STATE)',
              rom_consts[:SAVE_FOREGROUND_EVENT] == rom_consts[:SAVE_EVENT_EXEC_STATE])
  bytes = rom.first.size * 2 + rom.pairs.size * 2 + rom.ext.size * 12 + rom.words.size * 2 + rom.pool.bytesize +
          rom.doubles.size * 8
  puts "    tables: #{enc.nodes.size} nodes, #{rom.pairs.size / 2} pairs, #{rom.ext.size} ext entries, #{bytes} bytes"
  suite.check('the tables are small (under 24 KB)', bytes < 24_576)

  # --- readers -------------------------------------------------------------------------------------------
  # Every field of every table, through the same lcf.rb, once over the Hashes and once over the handles.
  # A record's inspect holds its schema, which is what differs; a value is shown by class and contents.
  show = ->(v) { v.is_a?(LCF::Array1D) || v.is_a?(LCF::Array2D) ? v.class.name : "#{v.class} #{v.inspect[0, 80]}" }
  probe = lambda do |tables|
    out = []
    tables.each do |name, table|
      rec = LCF::Array1D.new('', { elements: table })
      ids = LCF.skeys(LCF.elements_of({ elements: table }))
      ids.each do |id|
        field = LCF.sget(LCF.elements_of({ elements: table }), id)
        fname = LCF.sget(field, :name)
        v = rec[id]
        out << "#{name}[#{id}] #{fname} #{LCF.sget(field, :type)} #{show.call(v)} " \
               "#{rec.field?(fname)} #{LCF.int16_format(field)} #{show.call(rec[fname])}"
        next if v.nil? || v.is_a?(LCF::Array1D) || v.is_a?(LCF::Array2D) || v.is_a?(Hash)

        begin
          rec[id] = v
          out << "  written #{show.call(rec[id])} #{rec.key?(id)}"
        rescue StandardError => e
          out << "  write #{e.class}"
        end
      end
    end
    out.join("\n")
  end
  hash_tables = hash_consts.select { |_, v| v.is_a?(Hash) && !v.key?(:type) }
  rom_tables = rom_consts.slice(*hash_tables.keys)
  LCF.define_singleton_method(:rom_get) { |h, k| rom.get(h, k) }
  LCF.define_singleton_method(:rom_keys) { |h| rom.keys(h) }
  # cp932 is not under test: a String field reads as its bytes either way.
  LCF.define_singleton_method(:cp932_to_utf8) { |s| s.dup } unless LCF.respond_to?(:cp932_to_utf8)
  LCF.define_singleton_method(:utf8_to_cp932) { |s| s.dup } unless LCF.respond_to?(:utf8_to_cp932)
  a = probe.call(hash_tables)
  b = probe.call(rom_tables)
  suite.check("the readers answer the same over handles as over Hashes (#{a.lines.size} reads)", a == b && a.lines.size > 500)
  if a != b
    i = a.lines.zip(b.lines).index { |x, y| x != y }
    puts "    first difference: hash #{a.lines[i]}    rom  #{b.lines[i]}" if i
  end
  db_hash = hash_consts[:DATABASE]
  db_rom = rom_consts[:DATABASE]
  same_db = LCF.skeys(LCF.elements_of(db_hash)).all? do |id|
    fh = LCF.sget(LCF.elements_of(db_hash), id)
    fr = LCF.sget(LCF.elements_of(db_rom), id)
    sub = LCF.elements_of(fr)
    sub_h = LCF.elements_of(fh)
    (sub.nil? && sub_h.nil?) || (sub.is_a?(Integer) && LCF.skeys(sub) == LCF.skeys(sub_h) &&
      LCF.elements_of(fr).equal?(LCF.elements_of(fr)))
  end
  suite.check('every DATABASE record type has the same fields over its handle (lambdas included)', same_db)
  rec = LCF::Array1D.new('', LCF.sget(LCF.elements_of(db_rom), 11))
  suite.check('a ROM record keeps its name lookup off the handle (LCF::ROM_SYM2IDX)',
              rec.field?(:name) && LCF::ROM_SYM2IDX.key?(LCF.sget(LCF.elements_of(db_rom), 11)))

  # --- native --------------------------------------------------------------------------------------------
  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP native tables: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    # A full-core libmruby has no presym for the schema's names: the tables are written with each name's place in a
    # list (from 1) and check_hooks.hxx maps a word to that name's id there (LCF_ROM_WORD_SYM, schema_rom.hxx).
    names = (enc.nodes.flatten(1).flatten(1) + enc.words).select { |w| w[0] == :sym }.map { |w| w[1].to_s }.uniq.sort
    index = names.each_with_index.to_h { |n, i| [n, i + 1] }
    flags = %w[-std=c++17 -fexceptions -DMRB_USE_CXX_EXCEPTION -DLCF_SCHEMA_STRESS -w] + Bc2cppFixtureRuntime.library_defines(build)
    inc = ["-I#{dir}", "-I#{ROOT_DIR}/mruby-lcf/src", "-I#{build}/include", "-I#{ROOT_DIR}/3rd/mruby/include"]
    File.write(File.join(dir, 'check_hooks.hxx'), <<~CPP)
      #pragma once
      #include <mruby.h>
      #include <cstdint>
      extern mrb_sym lcf_check_syms[];
      extern const unsigned lcf_check_nsyms;
      inline uint16_t lcf_check_word(mrb_sym s) {
        for (unsigned i = 1; i <= lcf_check_nsyms; ++i) if (lcf_check_syms[i] == s) return (uint16_t)i;
        return 0;
      }
      #define LCF_ROM_WORD_SYM(w) lcf_check_syms[w]
      #define LCF_ROM_SYM_WORD(s) lcf_check_word(s)
      #define LCF_ROM_LEAVES_SYM(M) mrb_intern_lit(M, "__lcf_rom_leaves")
    CPP
    text = File.read(cc).gsub(/MRB_SYM\((\w+)\)/) { index.fetch(Regexp.last_match(1)).to_s }
    text = text.sub(/^static_assert\(MRB_PRESYM_MAX.*\n/, '').sub('#include <mruby.h>', "#include \"check_hooks.hxx\"\n#include <mruby.h>")
    File.write(File.join(dir, 'tables.cc'), text)
    intern = <<~CPP
      #include "check_hooks.hxx"
      #include <cstdio>
      #include <string>
      #include <vector>
      static const char* const check_names[] = {#{names.map { |n| %("#{n}") }.join(', ')}};
      const unsigned lcf_check_nsyms = #{names.size};
      mrb_sym lcf_check_syms[#{names.size + 1}];
    CPP
    walk_consts = rom_consts.flat_map do |c, v|
      next v.each_with_index.map { |x, i| %({"#{c}", #{x}, #{i.zero? ? 2 : 3}}) } if kinds[c] == Array

      [%({"#{c}", #{v}, #{kinds[c] == Hash ? 1 : 0}})]
    end.join(",\n  ")
    File.write(File.join(dir, 'main.cpp'), intern + <<~CPP)
      #include <mruby/array.h>
      #include <mruby/error.h>
      #include <mruby/string.h>
      #include <cstdlib>
      #include <map>
      #include "schema_rom.hxx"
      static std::map<long, int> marks;
      static std::map<const void*, int> leaves;
      static std::string out;
      static void scalar(mrb_state* M, mrb_value v) {
        if (mrb_nil_p(v)) out += "nil";
        else if (mrb_true_p(v)) out += "true";
        else if (mrb_false_p(v)) out += "false";
        else if (mrb_symbol_p(v)) { out += ":"; out += mrb_sym_name(M, mrb_symbol(v)); }
        else if (mrb_integer_p(v)) { out += "I" + std::to_string((long)mrb_integer(v)); }
        else if (mrb_float_p(v)) { mrb_value s = mrb_funcall(M, v, "to_s", 0); out += "F"; out.append(RSTRING_PTR(s), RSTRING_LEN(s)); }
        else { std::fprintf(stderr, "scalar of type %d\\n", (int)mrb_type(v)); std::exit(3); }
      }
      static bool node_key(mrb_state* M, mrb_value k) {
        return mrb_integer_p(k) || (mrb_symbol_p(k) && (mrb_symbol(k) == mrb_intern_lit(M, "elements") || mrb_symbol(k) == mrb_intern_lit(M, "enums")));
      }
      static void leaf(mrb_state* M, mrb_value v) {
        if (!mrb_string_p(v) && !mrb_array_p(v)) return scalar(M, v);
        auto it = leaves.find(mrb_ptr(v));
        if (it != leaves.end()) { out += "@" + std::to_string(it->second); return; }
        int n = (int)(marks.size() + leaves.size());
        leaves[mrb_ptr(v)] = n;
        out += "#" + std::to_string(n);
        if (mrb_string_p(v)) {
          out += "S(";
          for (mrb_int i = 0; i < RSTRING_LEN(v); ++i) { if (i) out += " "; out += std::to_string((unsigned char)RSTRING_PTR(v)[i]); }
          out += ")";
        } else {
          out += "[";
          for (mrb_int i = 0; i < RARRAY_LEN(v); ++i) { if (i) out += ","; leaf(M, RARRAY_PTR(v)[i]); }
          out += "]";
        }
      }
      static void node(mrb_state* M, mrb_value h) {
        if (mrb_nil_p(h)) { out += "nil"; return; }
        long id = (long)mrb_integer(h);
        auto it = marks.find(id);
        if (it != marks.end()) { out += "@" + std::to_string(it->second); return; }
        int n = (int)(marks.size() + leaves.size());
        marks[id] = n;
        out += "#" + std::to_string(n) + "{";
        mrb_value keys = lcf_rom::keys(M, h);
        int ai = mrb_gc_arena_save(M);
        for (mrb_int i = 0; i < RARRAY_LEN(keys); ++i) {
          mrb_value k = RARRAY_PTR(keys)[i];
          if (i) out += ",";
          scalar(M, k);
          out += "=>";
          mrb_value v = lcf_rom::get(M, h, k);
          if (node_key(M, k) && !mrb_symbol_p(v) && !mrb_nil_p(v)) node(M, v); else leaf(M, v);
          mrb_gc_arena_restore(M, ai);
        }
        out += "}";
      }
      // kind 0 an Integer, 1 a node, 2 the first node of an Array constant, 3 a later one.
      struct Const { const char* name; long handle; int kind; };
      static const Const consts[] = {
        #{walk_consts}
      };
      int main() {
        mrb_state* M = mrb_open();
        for (unsigned i = 0; i < lcf_check_nsyms; ++i) lcf_check_syms[i + 1] = mrb_intern_cstr(M, check_names[i]);
        mrb_define_module(M, "LCF");  // where the ext slots hang (mruby-lcf defines it)
        // Constants as the dump prints them: an Array constant's handles in one bracket.
        bool bracket = false;
        for (const Const& c : consts) {
          if (c.kind == 3) out += ",";
          else {
            if (bracket) { out += "]"; bracket = false; }
            if (&c != consts) out += "\\n";
            out += c.name; out += " ";
            if (c.kind == 2) { out += "["; bracket = true; }
          }
          if (c.kind == 0) scalar(M, mrb_fixnum_value(c.handle)); else node(M, mrb_fixnum_value(c.handle));
        }
        if (bracket) out += "]";
        std::printf("%s\\n", out.c_str());
        std::fflush(stdout);
        // Identity and the keys no Hash holds.
        mrb_value field = mrb_nil_value();
        for (unsigned n = 0; n < lcf_rom_node_count && mrb_nil_p(field); ++n) {
          mrb_value h = mrb_fixnum_value(-(mrb_int)n - 1);
          mrb_value d = lcf_rom::get(M, h, mrb_symbol_value(mrb_intern_lit(M, "default")));
          if (mrb_string_p(d)) field = h;
        }
        mrb_value dflt = mrb_symbol_value(mrb_intern_lit(M, "default"));
        mrb_value s1 = lcf_rom::get(M, field, dflt);
        mrb_full_gc(M);
        mrb_value s2 = lcf_rom::get(M, field, dflt);
        std::printf("same %d frozen %d\\n", (int)mrb_obj_eq(M, s1, s2), (int)mrb_frozen_p(mrb_basic_ptr(s1)));
        mrb_value h0 = mrb_fixnum_value(-1);
        std::printf("absent %d %d %d %d %d\\n", (int)mrb_nil_p(lcf_rom::get(M, h0, mrb_symbol_value(mrb_intern_lit(M, "zz_none")))),
                    (int)mrb_nil_p(lcf_rom::get(M, h0, mrb_fixnum_value(0x7fff))), (int)mrb_nil_p(lcf_rom::get(M, h0, mrb_fixnum_value(0x10001))),
                    (int)mrb_nil_p(lcf_rom::get(M, h0, mrb_str_new_lit(M, "name"))), (int)mrb_nil_p(lcf_rom::get(M, h0, mrb_nil_value())));
        mrb_value bad[] = {mrb_fixnum_value(0), mrb_fixnum_value(-(mrb_int)lcf_rom_node_count - 1), mrb_str_new_lit(M, "x")};
        for (mrb_value b : bad) {
          mrb_bool raised = FALSE;
          mrb_value args[2] = {b, dflt};
          mrb_protect_error(M, [](mrb_state* M, void* p) {
            mrb_value* a = static_cast<mrb_value*>(p);
            return lcf_rom::get(M, a[0], a[1]);
          }, args, &raised);
          M->exc = nullptr;
          std::printf("raises %d\\n", (int)raised);
        }
        mrb_close(M);
        return 0;
      }
    CPP
    bin = File.join(dir, 'walk')
    built = Bc2cppCxx.system(*flags, *inc, File.join(dir, 'main.cpp'), File.join(dir, 'tables.cc'),
                             "#{build}/lib/libmruby.a", '-lm', '-o', bin)
    suite.check('schema_rom.hxx builds with the generated tables', built)
    if built
      out, status = Open3.capture2e(bin)
      suite.check('the native walk runs with a full collection before every String/Array it makes', status.success?)
      puts out.lines.last(6).map { |l| l[0, 300] }.join unless status.success?
      lines = out.lines
      native = lines.take_while { |l| !l.start_with?('same ') }.join.chomp
      if native != want
        x = native.lines
        y = want.lines
        i = x.zip(y).index { |p, q| p != q }
        puts "    first difference at line #{i}:", "      native: #{x[i].to_s[0, 300]}", "      hash:   #{y[i].to_s[0, 300]}" if i
      end
      suite.check('the native walk gives the text of schema.rb, every shared object included', native == want)
      suite.check('a String default is one object across reads and a collection, and not frozen',
                  lines.include?("same 1 frozen 0\n"))
      suite.check('a key no schema Hash holds is nil: an unknown Symbol, an absent Integer, a wide one, a String, nil',
                  lines.include?("absent 1 1 1 1 1\n"))
      suite.check('a value that is no handle raises (0, one past the last node, a String)',
                  lines.count("raises 1\n") == 3)
    end
  end

  # --- closure -------------------------------------------------------------------------------------------
  # The readers (lcf.rb, lcf_file.rb, save_typed.rb, save_typed_put.rb): the only code that holds a schema value. Each pin is the
  # SHA256 of the method's source; a change to one is checked against what the readers may do with a handle (pass it
  # to sget/skeys/elements_of/Array1D.new/Array2D.new, compare it with equal?, test it with is_a?/nil) and re-pinned.
  readers = {
    'LCF.read_section' => nil, 'LCF.to_rb' => nil, 'LCF.int16_format' => nil, 'LCF.sget' => nil, 'LCF.skeys' => nil,
    'LCF.elements_of' => nil,
    'LCF::Array1D#initialize' => nil, 'LCF::Array1D#[]' => nil, 'LCF::Array1D#int16_values' => nil,
    'LCF::Array1D#[]=' => nil, 'LCF::Array1D#field?' => nil, 'LCF::Array1D#sym2idx' => nil,
    'LCF::Array2D#initialize' => nil, 'LCF::Array2D#[]' => nil, 'LCF::Array2D#[]=' => nil,
    'LCF::Array2D#same_schema?' => nil, 'LCF::Array1D.blank_record' => nil, 'LCF::Array2D.blank_table' => nil,
    'LCF::Array2D.lazy_section' => nil,
    'LCF::File#initialize' => nil, 'LCF::File#schema' => nil, 'LCF::File#build_root' => nil, 'LCF::File#to_lcf' => nil,
    'LCF::Database#schema' => nil, 'LCF::MapTree#schema' => nil, 'LCF::MapUnit#schema' => nil,
    'LCF::SaveData#schema' => nil, 'LCF::SaveTyped::Record#save_put' => nil, 'LCF::SaveTyped::Record#check!' => nil
  }
  pins = File.read(__FILE__)[/^# READER PINS\n(.*?)^# END READER PINS/m, 1].to_s.lines.to_h do |l|
    name, sha = l.delete_prefix('#').split
    [name, sha]
  end
  require File.join(BC2CPP_TREE_ROOT, 'tools/bc2cpp/compiled_gems')
  world = closed_world_mrblib_srcs(ROOT_DIR, core_gems: nil)
  engine = world.select { |p| p.include?('/mruby-rpg2k/') || p.include?('/mruby-lcf/') || p.include?('/mruby-rgss/') }
  table_consts = rom_consts.reject { |_, v| v.is_a?(Integer) && v >= 0 }.keys.map(&:to_s).to_set
  method_names = %w[schema elements_of sget skeys rom_get rom_keys].to_set
  violations = []
  seen = {}
  engine.each do |path|
    next if path == File.expand_path(HANDLES)

    rel = path.delete_prefix("#{ROOT_DIR}/")
    src = File.binread(path)
    walk = lambda do |node, scope, allowed|
      case node
      when Prism::ModuleNode, Prism::ClassNode
        scope = scope + [node.constant_path.slice]
      when Prism::DefNode
        owner = scope.join('::').sub(/\A(LCF::)?/, 'LCF::').sub(/\ALCF::LCF/, 'LCF')
        meth = node.receiver ? "#{owner}.#{node.name}" : "#{owner}##{node.name}"
        if readers.key?(meth)
          seen[meth] = Digest::SHA256.hexdigest(node.slice)[0, 16]
          allowed = true
        else
          allowed = false
        end
      when Prism::CallNode
        if method_names.include?(node.name.to_s) && !allowed
          violations << "#{rel}:#{node.location.start_line} #{node.name} outside the readers"
        end
        # Array1D#schema, the reader of @schema that save_put and Array2D#[]= call.
        if node.name == :attr_reader && scope.last == 'Array1D' && rel == 'mruby-lcf/mrblib/lcf.rb' &&
           node.arguments&.arguments&.map(&:slice) == [':schema']
          seen['LCF::Array1D#schema'] = 'attr_reader'
          return
        end
        # blank_record/blank_table (readers) only wrap their argument the same way.
        if %i[blank_record blank_table].include?(node.name) && node.receiver&.slice&.match?(/\A(LCF::)?Array[12]D\z/)
          arg = node.arguments&.arguments&.first
          (seen[:wrapped] ||= Set.new) << arg.object_id if arg
        end
        if %i[new].include?(node.name) && node.receiver&.slice&.match?(/\A(LCF::)?Array[12]D\z/)
          node.arguments&.arguments&.each do |arg|
            next unless arg.is_a?(Prism::HashNode) || arg.is_a?(Prism::KeywordHashNode)

            arg.elements.each do |el|
              next unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode) && el.key.unescaped == 'elements'

              # A schema constant handed straight to the record is the one place outside the readers it may be read.
              (seen[:wrapped] ||= Set.new) << el.value.object_id
            end
          end
        end
      when Prism::SymbolNode
        if method_names.include?(node.unescaped) && !allowed
          violations << "#{rel}:#{node.location.start_line} :#{node.unescaped} outside the readers"
        end
      when Prism::InstanceVariableReadNode, Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode,
           Prism::InstanceVariableAndWriteNode, Prism::InstanceVariableOperatorWriteNode
        if node.name == :@schema && !(allowed && %w[Array1D Array2D].include?(scope.last))
          violations << "#{rel}:#{node.location.start_line} @schema outside LCF::Array1D/Array2D's readers"
        end
      when Prism::ConstantPathNode, Prism::ConstantReadNode
        name = node.is_a?(Prism::ConstantPathNode) ? node.name.to_s : node.name.to_s
        schema_ref = node.is_a?(Prism::ConstantPathNode) ? node.parent&.slice&.match?(/\A(::)?(LCF::)?Schema\z/) : scope.last == 'Schema'
        if schema_ref && table_consts.include?(name) && !allowed && !(seen[:wrapped]&.include?(node.object_id))
          violations << "#{rel}:#{node.location.start_line} LCF::Schema::#{name} read outside the readers"
        end
        return if node.is_a?(Prism::ConstantPathNode)
      end
      node.compact_child_nodes.each { |c| walk.call(c, scope, allowed) }
    end
    walk.call(Prism.parse(src).value, [], false)
  end
  missing = readers.keys - seen.keys
  missing -= ['LCF::Array1D#schema']
  suite.check("every reader is in the world (#{readers.size}#{missing.empty? ? '' : ", missing #{missing.join(', ')}"})", missing.empty?)
  puts violations.first(20).map { |v| "    #{v}" }
  suite.check('no schema value is made or read outside the readers in the closed world', violations.empty?)
  changed = readers.keys.reject { |m| pins[m] == seen[m] }
  changed.each { |m| puts "    #{m} #{seen[m]} (pinned #{pins[m] || 'none'})" }
  suite.check('the readers are the reviewed ones (READER PINS)', changed.empty?)

  # --- switch --------------------------------------------------------------------------------------------
  on = lcf_mrblib_srcs(ROOT_DIR)
  saved = ENV.fetch('BC2CPP_ROM_SCHEMA', nil)
  ENV['BC2CPP_ROM_SCHEMA'] = '0'
  off = lcf_mrblib_srcs(ROOT_DIR)
  saved.nil? ? ENV.delete('BC2CPP_ROM_SCHEMA') : ENV['BC2CPP_ROM_SCHEMA'] = saved
  suite.check('the world compiles mrblib_rom/schema.rb in place of schema.rb',
              on.include?(HANDLES) && !on.include?(SCHEMA) && on.size == off.size)
  suite.check('BC2CPP_ROM_SCHEMA=0 compiles schema.rb', off.include?(SCHEMA) && !off.include?(HANDLES))
end

suite.finish!

# READER PINS
# LCF.read_section 370a45e73090ffd6
# LCF.to_rb 5f3f225846b27d15
# LCF.int16_format 99da2f9273aac7ef
# LCF.sget f352029d7ab23e37
# LCF.skeys 1d6cf657876a6c81
# LCF.elements_of dd92622942b68777
# LCF::Array1D#initialize 9551966272c2ebc0
# LCF::Array1D#[] 992d879cf7195afb
# LCF::Array1D#int16_values aebb3152a4747b5d
# LCF::Array1D#[]= 4af3eb957f4d25df
# LCF::Array1D#field? b6c72477f79534c7
# LCF::Array1D#sym2idx 846fdfdfb6e4edbb
# LCF::Array2D#initialize ceb5854322c5e4a9
# LCF::Array2D#[] 0bd3d8ee88588dc7
# LCF::Array2D#[]= 8f62693a42874353
# LCF::Array2D#same_schema? 46dfcbb99268bcd5
# LCF::Array1D.blank_record 67a22e0df0d5c2c1
# LCF::Array2D.blank_table b85106192df023c6
# LCF::Array2D.lazy_section 6c2733a3ebac90bf
# LCF::File#initialize 039a091fbcb7f542
# LCF::File#schema 417816763ff50949
# LCF::File#build_root 427cef6960ffe7fe
# LCF::File#to_lcf c01e042875ee2a2c
# LCF::Database#schema df1c5801d86d8400
# LCF::MapTree#schema 4ef7952dcbcc0bd4
# LCF::MapUnit#schema 613a882d7dd4339d
# LCF::SaveData#schema 8b872a23be8560fd
# LCF::SaveTyped::Record#save_put 1a444d4700f096a3
# LCF::SaveTyped::Record#check! f7d373d7020cad0d
# END READER PINS
