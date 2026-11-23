#!/usr/bin/env ruby
# frozen_string_literal: true

# PRESYM_NAMES: the engine's native sources name methods, ivars and constants by presym id (MRB_SYM, MRB_IVSYM,
# mrb_funcall_id, mrb_module_get_id, ...) instead of a string literal, which costs a name lookup on every call.
#
#   ruby scripts/native/presym_names.rb check [FILE...]   # fails on a literal-name lookup a presym could spell
#   ruby scripts/native/presym_names.rb write [FILE...]   # rewrites them (run clang-format afterwards)
#
# A presym id names the same symbol the literal interns, and every name a gem's sources spell is in its build's
# presym table, so the call is the same. Left as literals: mrb_const_set / mrb_define_* arguments and a lookup
# that names a definition's outer scope, which bc2cpp's binding scans (UniqueClassNames, ConstBindings) read.
require 'set'

module PresymNames
  ROOT = File.expand_path('../..', __dir__)
  # Not mruby-lcf's schema headers: lcf_schema_{rom,tables}_check build them against a plain libmruby's presyms.
  SOURCES = %w[mruby-rgss/src/*.cxx mruby-lcf/src/*.cxx mruby-rpg2k/src/*.cxx].freeze
  OPERATORS = {
    '!' => 'not', '%' => 'mod', '&' => 'and', '*' => 'mul', '+' => 'add', '-' => 'sub', '/' => 'div', '<' => 'lt',
    '>' => 'gt', '^' => 'xor', '`' => 'tick', '|' => 'or', '~' => 'neg', '!=' => 'neq', '!~' => 'nmatch',
    '**' => 'pow', '+@' => 'plus', '-@' => 'minus', '<<' => 'lshift', '<=' => 'le', '==' => 'eq', '=~' => 'match',
    '>=' => 'ge', '>>' => 'rshift', '[]' => 'aref', '<=>' => 'cmp', '===' => 'eqq', '[]=' => 'aset'
  }.freeze
  # function => [presym-id form, index of the name argument, constant name only?]
  RULES = {
    'mrb_intern_lit' => [nil, 1, false], 'mrb_intern_cstr' => [nil, 1, false],
    'mrb_module_get' => ['mrb_module_get_id', 1, true], 'mrb_class_get' => ['mrb_class_get_id', 1, true],
    'mrb_class_get_under' => ['mrb_class_get_under_id', 2, true],
    'mrb_module_get_under' => ['mrb_module_get_under_id', 2, true],
    'mrb_class_defined' => ['mrb_class_defined_id', 1, true],
    'mrb_class_defined_under' => ['mrb_class_defined_under_id', 2, true],
    'mrb_funcall' => ['mrb_funcall_id', 2, false]
  }.freeze
  VERBATIM = /\Amrb_(?:const_set|define_\w+)\z/
  CALL = /\b(#{RULES.keys.sort_by { -_1.size }.join('|')}|mrb_const_set|mrb_define_\w+)\s*\(/
  OUTER = /mrb_(?:define_\w+_under\w*|const_set)\s*\(\s*\w+\s*,\s*(?:mrb_obj_value\()?\s*(\w+)/
  LITERAL = /"(?:[^"\\]|\\.)*"/
  NAME_ARG = /\A\s*"((?:[^"\\]|\\.)*)"\s*\z/m
  TERNARY_ARG = /\A(.*\?\s*)"((?:[^"\\]|\\.)*)"(\s*:\s*)"((?:[^"\\]|\\.)*)"(\s*)\z/m

  module_function

  def sym_macro(name)
    case name
    when /\A@@([A-Za-z_]\w*)\z/ then "MRB_CVSYM(#{Regexp.last_match(1)})"
    when /\A@([A-Za-z_]\w*)\z/ then "MRB_IVSYM(#{Regexp.last_match(1)})"
    when /\A\$([A-Za-z_]\w*)\z/ then "MRB_GVSYM(#{Regexp.last_match(1)})"
    when /\A([A-Za-z_]\w*)([?!=])?\z/
      "MRB_SYM#{{ '?' => '_Q', '!' => '_B', '=' => '_E' }[Regexp.last_match(2)]}(#{Regexp.last_match(1)})"
    else OPERATORS[name] && "MRB_OPSYM(#{OPERATORS[name]})"
    end
  end

  # [arguments, index past ')'] of the call whose '(' is at text[open]; nil when unbalanced.
  def split_args(text, open)
    depth = 0
    start = open + 1
    args = []
    i = open
    while i < text.size
      case (c = text[i])
      when '"', "'"
        i += 1
        i += (text[i] == '\\' ? 2 : 1) while i < text.size && text[i] != c
      when '(', '[', '{' then depth += 1
      when ')', ']', '}'
        depth -= 1
        return [args << text[start...i], i + 1] if depth.zero?
      when ','
        if depth == 1
          args << text[start...i]
          start = i + 1
        end
      end
      i += 1
    end
    nil
  end

  def name_arg(arg, constant)
    conv = ->(s) { !s.include?('\\') && (!constant || s.match?(/\A[A-Z]\w*\z/)) && sym_macro(s) }
    if (m = arg.match(NAME_ARG))
      (r = conv.call(m[1])) && arg.sub(LITERAL) { r }
    elsif (m = arg.match(TERNARY_ARG))
      (a = conv.call(m[2])) && (b = conv.call(m[4])) && "#{m[1]}#{a}#{m[3]}#{b}#{m[5]}"
    end
  end

  # +text+ with every rewritable lookup in presym form; +hits+ collects [function, line] of each.
  def rewrite(text, outers = text.scan(OUTER).flatten.to_set, hits = [], base = 0, whole = text)
    out = +''
    pos = 0
    while (m = CALL.match(text, pos))
      out << text[pos...m.begin(0)]
      fn = m[1]
      args, after = split_args(text, m.end(0) - 1)
      outer = fn.end_with?('_get') && text[0...m.begin(0)][/(\w+)\s*=\s*\z/, 1]
      if args.nil? || fn.match?(VERBATIM) || outers.include?(outer)
        pos = args ? after : m.end(0)
        out << text[m.begin(0)...pos]
        next
      end
      args = args.each_with_index.map do |a, i|
        inner = text.index(a, m.end(0) + args[0...i].sum { _1.size + 1 }) || m.end(0)
        rewrite(a, outers, hits, base + inner, whole)
      end
      renamed, index, constant = RULES.fetch(fn)
      name = args.size > index && name_arg(args[index], constant)
      if name
        hits << [fn, whole[0...base + m.begin(0)].count("\n") + 1]
        args[index] = name
        out << (renamed ? "#{renamed}(#{args.join(',')})" : name.strip)
      else
        out << text[m.begin(0)...m.end(0)] << args.join(',') << ')'
      end
      pos = after
    end
    out << text[pos..]
  end

  def files(argv)
    argv.empty? ? SOURCES.flat_map { |glob| Dir[File.join(ROOT, glob)] }.sort : argv
  end
end

if $PROGRAM_NAME == __FILE__
  mode, *paths = ARGV
  abort 'usage: presym_names.rb check|write [FILE...]' unless %w[check write].include?(mode)
  found = 0
  PresymNames.files(paths).each do |path|
    src = File.read(path)
    hits = []
    dst = PresymNames.rewrite(src, src.scan(PresymNames::OUTER).flatten.to_set, hits)
    found += hits.size
    hits.each { |fn, line| puts "#{path.delete_prefix("#{PresymNames::ROOT}/")}:#{line}: #{fn} with a literal name" }
    File.write(path, dst) if mode == 'write' && dst != src
  end
  exit(found.zero? || mode == 'write' ? 0 : 1)
end
