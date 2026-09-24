#!/usr/bin/env ruby
# encoding: UTF-8
# Check that a nested compile (compiles_clean? probing a callee in the middle
# of another method's compile) neither sees nor clobbers the caller's
# per-method state (ADR 0202). Each fixture method calls a MONO helper inside a
# block-fallback body, then uses state the helper's own compile used to clear:
# an upvar write, a forwarded `yield`, a `break`. The result must not depend on
# whether the helper was already memoized.
#
# Also checks that METHOD_COMPILE_STATE lists every ivar CodeGen writes outside
# its constructor, except the memo caches, output accumulators and
# constructor-time proofs named below.

require 'tmpdir'
require_relative '../tools/bc2cpp/bc2cpp'

root = File.expand_path('..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

SOURCE = <<~'RUBY'
  class Pages
    def helper(x)
      x.each { |y| y }
    end

    def changed?(list)
      acc = 0
      list.each { |v| helper(v); acc = v }
      acc
    end

    def each_page(list)
      list.each { |v| helper(v); yield v }
    end

    def first_page(list)
      list.each { |v| helper(v); break v if v }
    end
  end
RUBY

ireps, registry = Dir.mktmpdir do |dir|
  path = File.join(dir, 'pages.rb')
  File.write(path, SOURCE)
  c_dump, disasm = run_mrbc(path, 'bc2cpp_pages', dir)
  parsed, root_label = parse_c_dump(c_dump, 'bc2cpp_pages')
  order = dfs_order(parsed, root_label)
  blocks, block_files, block_catches = parse_disasm_blocks(disasm)
  merge!(parsed, order, blocks, block_files, block_catches)
  [parsed, build_registry(parsed, root_label)[0]]
end
new_gen = -> { CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new) }
label = ->(name) { registry.fetch(name).find { |d| d.owner == 'Pages' }.irep }
state_of = ->(gen) { CodeGen::METHOD_COMPILE_STATE.keys.to_h { |ivar| [ivar, gen.instance_variable_get(ivar)] } }

{ 'changed?' => 'an upvar write', 'each_page' => 'a forwarded yield', 'first_page' => 'a break' }.each do |name, what|
  cold = new_gen.call
  cold_code = cold.compile_method(label.call(name)).fetch(:code)
  warm = new_gen.call
  warm.compiles_clean?(label.call('helper'))
  warm_code = warm.compile_method(label.call(name)).fetch(:code)
  check.call("#{name}: #{what} after a first-time helper probe compiles clean", !cold_code.include?('#error'))
  check.call("#{name}: the code does not depend on whether the helper was memoized", cold_code == warm_code)
  check.call("#{name}: its own memo is clean", new_gen.call.compiles_clean?(label.call(name)))
  check.call("#{name}: every per-method ivar is back at its top-level value",
             state_of.call(cold) == CodeGen::METHOD_COMPILE_STATE)
end
first_page = new_gen.call.compile_method(label.call('first_page')).fetch(:code)
check.call('first_page: the block break still throws out of the block cfunc',
           first_page.include?('throw bc2cpp_block_break{'))

fresh = new_gen.call
check.call('METHOD_COMPILE_STATE matches the constructor\'s initial values',
           CodeGen::METHOD_COMPILE_STATE.all? { |ivar, v| fresh.instance_variable_get(ivar) == v })

# Every ivar written outside `initialize`, split by what it is.
NOT_PER_METHOD = %w[
  @clean_cache @probing
  @builtin_class_send_safe @entry_arg_body_owner @entry_arg_call_index @eqq_literal_devirt_safe
  @fixnum_proof_ctx @fixnum_proof_preds @keyword_never_defined_universe @known_owner_set @subclassed_set
  @own_upvar_written_regs @symbol_installed_names
  @const_lookup_helper_used @const_site_cache @direct_construct_used @index_helper_code @native_construct_used
  @owner_class_cache @synthesize_accessor_for @poly_tables @poly_tables_emitted
  @array_return_names @class_return_names @entry_arg_fixnum @fixnum_return_names @fiber_unsafe_methods
  @ivar_layout @only_owners @other_owners
].freeze
# CodeGen is reopened across several tools/bc2cpp files (scripts/bc2cpp_split.rb).
written = Set.new
blocks = 0
Dir[File.join(root, 'tools/bc2cpp/*.rb')].sort.each do |path|
  lines = File.readlines(path)
  lines.each_index.select { |i| lines[i] == "class CodeGen\n" }.each do |first|
    blocks += 1
    last = first + lines[first..].index("end\n")
    in_init = false
    lines[first..last].each do |line|
      in_init = true if line.start_with?('  def initialize(')
      in_init = false if in_init && line == "  end\n"
      next if in_init

      code = line.sub(/(^|\s)#.*$/, '')
      code.scan(/(@[a-z_]\w*)\s*(?:\|\|=|\+=|<<|=(?![=~]))/) { |(ivar)| written << ivar }
    end
  end
end
check.call("CodeGen's source is found (#{blocks} class bodies)", blocks.positive?)
unlisted = written.to_a - CodeGen::METHOD_COMPILE_STATE.keys.map(&:to_s) - NOT_PER_METHOD
check.call("every ivar written outside the constructor is classified#{unlisted.empty? ? '' : " (not: #{unlisted.sort.join(', ')})"}",
           unlisted.empty?)

if failures.empty?
  puts 'bc2cpp nested compile state check: PASS'
else
  warn "bc2cpp nested compile state check: #{failures.size} failure(s)"
  exit 1
end
