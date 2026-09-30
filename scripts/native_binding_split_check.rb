#!/usr/bin/env ruby
# encoding: UTF-8
# Check the RGSS native binding split (ADR 0263) without a compiler.
#
#   - the classifier and the rewrite, on a fixture translation unit
#     (scripts/fixtures/native_binding_split) whose libclang facts are checked
#     in: every outcome, the guard model, the source rewrite (against a golden
#     copy) and the generated forwarder block and header;
#   - the tree itself: what scripts/native_binding_split.rb `write` leaves
#     behind must still hold -- every entry point the compiler's table names is
#     declared, defined in lib.cxx and forwards to a function that is a binding
#     or the body of one; no `*_native_body` function reads the caller's frame;
#     the generated table, header and block agree.
#
# What this cannot see is a binding that became splittable (or stopped being
# frame-independent) since the last `write`: that needs libclang, so
# `scripts/native_binding_split.rb check` (run in the `clang` dev shell) is the
# full freshness check. UPDATE_GOLDEN=1 rewrites the golden fixture output.
require 'json'
require 'set'
require 'tmpdir'
require_relative '../tools/bc2cpp/native_binding_split_rewrite'
require_relative '../tools/bc2cpp/native_direct'

NBS = NativeBindingSplit
root = File.expand_path('..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# -- guard model ---------------------------------------------------------------

puts 'guards'
holds = ->(clauses, config) { NBS::GuardEval.holds?(clauses, config) }
check.call('!defined(WIO_TERMINAL) holds everywhere but wio',
           %w[host wio psp maix].map { |c| holds.call(['!defined(WIO_TERMINAL)'], c) } == [true, false, true, true])
check.call('a conjunction needs every clause',
           holds.call(['!defined(WIO_TERMINAL)', '!defined(MAIX_BUILD)'], 'maix') == false &&
             holds.call(['!defined(WIO_TERMINAL)', '!defined(MAIX_BUILD)'], 'psp') == true)
check.call('|| and parentheses', holds.call(['defined(PSP_BUILD) || (defined(WIO_TERMINAL) && !defined(MAIX_BUILD))'], 'wio') == true)
check.call('an empty guard always holds', holds.call([], 'wio') == true)
check.call('a macro the model does not know is unproven, not false', holds.call(['LV_USE_SNAPSHOT'], 'host').nil?)
check.call('no guard (an #elif) is unproven', holds.call(nil, 'host').nil?)

src = NBS::Source.new('fake.cxx', <<~CXX)
  int a;
  #if !defined(WIO_TERMINAL)  // dead weight on wio
  int b;
  #  if defined(PSP_BUILD) && \\
       !defined(MAIX_BUILD)
  int c;
  #  else
  int d;
  #  endif
  /* #if hidden */
  #endif
  // #ifdef NOPE
  int e;
  #ifdef X
  #elif Y
  int f;
  #endif
CXX
at = ->(text) { src.guard_at(src.bytes.index(text)) }
check.call('no directive above: no guard', at.call('int a') == [])
check.call('an #if with a trailing comment', at.call('int b') == ['!defined(WIO_TERMINAL)'])
check.call('nested guards and a continued line stack up',
           at.call('int c') == ['!defined(WIO_TERMINAL)', 'defined(PSP_BUILD) && !defined(MAIX_BUILD)'])
check.call('an #else negates its #if', at.call('int d') == ['!defined(WIO_TERMINAL)', '!(defined(PSP_BUILD) && !defined(MAIX_BUILD))'])
check.call('comments do not open or close a conditional', at.call('int e') == [])
check.call('an #elif makes the guard unprovable', at.call('int f').nil?)
check.call('a conditional inside a range is seen', src.conditional_inside?([src.bytes.index('int b'), src.bytes.index('int d')]))
check.call('and one outside it is not', !src.conditional_inside?([src.bytes.index('int a'), src.bytes.index('int a') + 5]))

# -- the fixture ----------------------------------------------------------------

puts 'fixture'
fixture_dir = File.join(root, 'scripts/fixtures/native_binding_split')
fixture_file = 'scripts/fixtures/native_binding_split/bindings.cxx'
facts = NBS.load_facts({ 'host' => File.join(fixture_dir, 'facts_host.json'), 'wio' => File.join(fixture_dir, 'facts_wio.json') }, root)
sources = { fixture_file => NBS::Source.new(File.join(root, fixture_file)) }
bindings, problems = NBS.classify_all(facts, sources)
problems.concat(NBS.apply_presence(bindings, facts))
check.call('the fixture parses cleanly in both configurations and its guards predict where each binding exists', problems.empty?)
by_name = bindings.to_h { |b| [b.name, b] }
expect = {
  'x=' => :splittable, 'pair' => :splittable, 'x' => :frame_free, 'flag=' => :splittable, 'twice' => :splittable,
  'zero' => :frame_free, 'forwards' => :forwarded
}
expect.each { |name, status| check.call("#{name} is #{status}", by_name.fetch(name).verdict.status == status) }
refusals = {
  'argc' => 'frame_api:mrb_get_argc', 'optional' => 'get_args_format:|', 'first' => 'statement_before_get_args',
  'block' => 'frame_api:mrb_yield', 'hidden' => 'get_args_in_callee', 'jump' => 'goto', 'ifdef' => 'ifdef_in_body',
  'mid' => 'frame_api:mrb_get_mid', 'member' => 'get_args_targets'
}
refusals.each do |name, reason|
  v = by_name.fetch(name).verdict
  check.call("#{name} is refused: #{reason}", v.status == :refused && v.reasons.first.first == reason)
end
check.call('the block binding is refused for its & format too',
           by_name['block'].verdict.reasons.map(&:first).include?('get_args_format:&'))
check.call('a hand-written forwarder is recognised and its entry point named',
           by_name['forwards'].verdict.function == 'fixture_named_direct' && by_name['forwards'].verdict.kinds == [:int])
check.call('typed parameters come from the declarations', by_name['pair'].verdict.params == [%w[a mrb_int], %w[b mrb_int]])
check.call('a binding compiled off wio only is present in host alone', by_name['flag='].configs == ['host'])
check.call('owners are attributed', by_name['x='].owner == 'Fixture' && by_name['twice'].owner == 'Fixture.singleton')

# a configuration that classifies a binding differently refuses it
skewed = JSON.parse(File.read(File.join(fixture_dir, 'facts_wio.json')))
skewed['files'][fixture_file]['registrations'].find { |r| r['name'] == 'x=' }['target']['reasons'] << 'frame_api:mrb_get_argc'
skew_dir = Dir.mktmpdir
File.write(File.join(skew_dir, 'facts_wio.json'), JSON.generate(skewed))
skewed_facts = NBS.load_facts({ 'host' => File.join(fixture_dir, 'facts_host.json'), 'wio' => File.join(skew_dir, 'facts_wio.json') }, root)
skewed_bindings, = NBS.classify_all(skewed_facts, sources)
check.call('configurations that disagree on a binding refuse it',
           skewed_bindings.find { |b| b.name == 'x=' }.verdict.then { |v| v.status == :refused && v.reasons.first.first == 'config_disagreement' })

names = Set.new(%w[set_x_direct])
_units, rejected = NBS.plan_units(bindings, sources, names)
check.call('plan: a taken direct name rejects the unit', rejected.any? { |b, why| b.name == 'x=' && why.include?('set_x_direct') })
units, rejected = NBS.plan_units(bindings, sources, Set.new)
check.call('plan: six units, no rejections', units.size == 6 && rejected.empty?)
check.call('plan: lambdas are named from their class and method',
           units.map(&:body_name).include?('fixture_s_twice_native_body') && units.map(&:body_name).include?('fixture_zero_native_body'))

edits = units.flat_map(&:edits)
after = NBS.apply_edits(sources[fixture_file].bytes, edits)
golden_path = File.join(fixture_dir, 'bindings.split.cxx')
File.binwrite(golden_path, after) if ENV['UPDATE_GOLDEN']
# clang-format re-flows the golden copy, so compare without whitespace
check.call('the rewritten fixture matches its golden copy',
           File.exist?(golden_path) && File.binread(golden_path).gsub(/\s+/n, '') == after.gsub(/\s+/n, ''))
text = after.dup.force_encoding('UTF-8')
check.call('the body moves out, the wrapper keeps get_args and forwards',
           text.include?('mrb_value set_x_native_body(mrb_state* M, mrb_value self, mrb_int x) {') &&
             text.match?(/mrb_value set_x\(mrb_state\* M, mrb_value self\) \{\s*mrb_int x;\s*mrb_get_args\(M, "i", &x\);\s*return set_x_native_body\(M, self, x\);\s*\}/))
check.call('a body appears once: the wrapper no longer holds it', text.scan('mrb_iv_set(M, self, mrb_intern_lit(M, "@x")').size == 1)
check.call('an unnamed self parameter gets a name in the wrapper only',
           text.include?('mrb_value set_pair_native_body(mrb_state* M, mrb_value, mrb_int a, mrb_int b)') &&
             text.include?('mrb_value set_pair(mrb_state* M, mrb_value self)') && text.include?('return set_pair_native_body(M, self, a, b);'))
check.call('a frame-independent lambda is lifted ahead of its function and registered by name',
           text.include?('static mrb_value fixture_zero_native_body(mrb_state* M, mrb_value self)') &&
             text.match?(/mrb_define_method\(\s*M, c, "zero", fixture_zero_native_body/))
check.call('a splittable lambda keeps a thin lambda that unpacks and forwards',
           text.include?('static mrb_value fixture_s_twice_native_body(mrb_state* M, mrb_value self, mrb_int n)') &&
             text.include?('return fixture_s_twice_native_body(M, self, n);'))
check.call('a binding under #if keeps its body and wrapper under it',
           text =~ /#if !defined\(WIO_TERMINAL\)\n\/\/ splittable, compiled off wio only\nmrb_value off_wio_set_native_body/)
check.call('refused bindings are untouched', text.include?('mrb_value uses_argc(mrb_state* M, mrb_value self) {') && text.include?('mrb_value optional(mrb_state* M, mrb_value self) {'))

forwarders = units.map { |u| NBS.forwarder_from_unit(u) }.sort_by(&:direct_name)
block = NBS.render_block(forwarders)
header = NBS.render_header(forwarders)
check.call('the block is delimited and in namespace rgss',
           block.start_with?("#{NBS::BLOCK_BEGIN}\nnamespace rgss {") && block.end_with?("}  // namespace rgss\n#{NBS::BLOCK_END}\n"))
check.call('a forwarder passes its arguments through',
           block.include?("mrb_value set_x_direct(mrb_state* M, mrb_value self, mrb_int x) {\n  return set_x_native_body(M, self, x);\n}"))
check.call('a frame-free binding is forwarded to itself', block.include?("mrb_value get_x_direct(mrb_state* M, mrb_value self) {\n  return get_x(M, self);\n}"))
check.call('an entry point compiled off wio gets a raising stub for wio',
           block.include?("#if !defined(WIO_TERMINAL)\nmrb_value off_wio_set_direct(mrb_state* M, mrb_value self, mrb_bool flag) {\n  return off_wio_set_native_body(M, self, flag);\n}\n#else\n" \
                          "mrb_value off_wio_set_direct(mrb_state* M, mrb_value self, mrb_bool) {\n  return native_split_compiled_out(M, self);\n}\n#endif"))
check.call('the header declares exactly what the block defines',
           header.scan(/^mrb_value (\w+_direct)\(/).flatten.sort == block.scan(/^mrb_value (\w+_direct)\(mrb_state\* M, mrb_value self(?:, [^)]*)?\) \{\n  return \w+\(/).flatten.uniq.sort)

entries, conflicts = NBS.table_entries(bindings, units.each_with_object({}) { |u, h| u.bindings.each { |b| h[b] = u.direct_name } })
check.call('the table lists forwarded, planned and delegated entries with argument kinds, and no conflicts',
           conflicts.empty? && entries['x='] == { 'Fixture' => ['set_x_direct', [:int]] } &&
             entries['forwards']['Fixture'] == ['fixture_named_direct', [:int]] && entries['argc'].nil? &&
             entries['twice'] == { 'Fixture.singleton' => ['fixture_s_twice_direct', [:int]] })
clash = Struct.new(:name, :owner, :verdict, :label).new('x=', 'A', NBS::Verdict.new(status: :forwarded, function: 'a_direct', kinds: [:int]), 'A#x=')
clash2 = Struct.new(:name, :owner, :verdict, :label).new('x=', 'A', NBS::Verdict.new(status: :forwarded, function: 'b_direct', kinds: [:int]), 'A#x=')
entries, conflicts = NBS.table_entries([clash, clash2], {})
check.call('two registrations of one name that disagree get no entry', entries.empty? && conflicts.size == 1)

# -- the tree ---------------------------------------------------------------------

puts 'tree'
lib_path = File.join(root, 'mruby-rgss/src/lib.cxx')
lib = File.read(lib_path)
gen_header = File.read(File.join(root, NBS::HEADER_PATH))
old_header = File.read(File.join(root, 'include/rgss_construct.hxx'))
check.call('rgss_construct.hxx includes the generated header', old_header.include?('#include "rgss_native_direct.hxx"'))
check.call('lib.cxx has exactly one generated block',
           lib.scan(NBS::BLOCK_BEGIN).size == 1 && lib.scan(NBS::BLOCK_END).size == 1 && lib.index(NBS::BLOCK_BEGIN) < lib.index(NBS::BLOCK_END))
tree_block = lib[/#{Regexp.escape(NBS::BLOCK_BEGIN)}.*#{Regexp.escape(NBS::BLOCK_END)}/m].to_s

declared = gen_header.scan(/mrb_value\s+(\w+)\(([^)]*)\)\s*;/m).to_h { |fn, params| [fn, params.split(',').map(&:strip)] }
defined = {}
tree_block.scan(/^mrb_value (\w+)\(([^)]*)\)\s*\{\s*return (\w+)\(([^)]*)\);\s*\}/m) do |fn, params, callee, args|
  (defined[fn] ||= []) << { params: params.split(',').map(&:strip), callee: callee, args: args.split(',').map(&:strip) }
end
check.call('every generated declaration is defined in the block, and only those', defined.keys.sort == declared.keys.sort)
real = defined.transform_values { |defs| defs.reject { |d| d[:callee] == 'native_split_compiled_out' } }
check.call('a definition is either the forwarder or its raising stub, each name at most once each',
           defined.all? { |_fn, defs| defs.size <= 2 && defs.count { |d| d[:callee] == 'native_split_compiled_out' } <= 1 })
check.call('a forwarder passes its own parameters, in order, to its callee',
           real.all? do |fn, defs|
             defs.all? do |d|
               names = d[:params].map { |p| p[/(\w+)\z/, 1] }
               d[:args] == names && names.first(2) == %w[M self] && d[:params].size == declared.fetch(fn).size
             end
           end)

def function_text(source, name)
  start = source.index(/^(?:static )?mrb_value #{Regexp.escape(name)}\([^)]*\)\s*\{/m)
  return nil unless start

  open_at = source.index('{', source.index(name, start))
  depth = 0
  i = open_at
  while i < source.size
    depth += 1 if source[i] == '{'
    if source[i] == '}'
      depth -= 1
      return source[start..i] if depth.zero?
    end
    i += 1
  end
  nil
end

FRAME = /\bmrb_(?:get_args|get_argc|get_argv|get_arg1|block_given_p|get_mid|yield\w*|proc_cfunc_env_get|call_super|notimplement|argnum_error)\b|->ci\b|->c->/
callees = real.values.flatten.map { |d| d[:callee] }.uniq
check.call('every forwarder calls a function lib.cxx defines exactly once',
           callees.all? { |c| lib.scan(/^(?:static )?mrb_value #{Regexp.escape(c)}\(/).size == 1 })
bodies = callees.select { |c| c.end_with?('_native_body') }
check.call('there are split bodies', bodies.size >= 40)
bodies.each do |body|
  text = function_text(lib, body)
  check.call("#{body} exists and reads nothing from the calling frame", text && !text.match?(FRAME))
  base = body.delete_suffix('_native_body')
  wrapped = lib.match?(/mrb_get_args\([^;]*\);\s*return #{Regexp.escape(body)}\(/) ||
            lib.match?(/mrb_define_\w+\(\s*M,\s*\w+,\s*"[^"]+",\s*#{Regexp.escape(body)},/m)
  check.call("#{body} is called from a binding that unpacks mrb_get_args, or is registered as one", wrapped)
  check.call("#{base}_direct is declared for #{body}", declared.key?("#{NBS.direct_name(body)}"))
end
frame_free = callees - bodies
frame_free.each do |fn|
  text = function_text(lib, fn)
  check.call("#{fn} (forwarded to as it is) reads nothing from the calling frame", text && !text.match?(FRAME))
end

table = NativeDirect::GENERATED
all_declared = declared.merge(old_header.scan(/mrb_value\s+(\w+)\(([^)]*)\)\s*;/m).to_h { |fn, params| [fn, params.split(',').map(&:strip)] })
table.each do |name, owners|
  owners.each do |owner, (function, kinds)|
    arity = 2 + kinds.sum { |k| k == :str ? 2 : 1 }
    check.call("#{owner}##{name}: #{function} is declared with #{arity} parameters", all_declared[function]&.size == arity)
    check.call("#{owner}##{name}: #{function} is defined in lib.cxx", lib.match?(/^mrb_value #{Regexp.escape(function)}\(mrb_state\* M/))
  end
end
check.call('the table is sorted by name (as the generator writes it)', table.keys == table.keys.sort)
ENTRY_KINDS = %i[value int bool float sym string array hash cstr str].freeze
check.call('table kinds are ones the generator knows', table.values.all? { |o| o.values.all? { |(_, ks)| ks.all? { |k| ENTRY_KINDS.include?(k) } } })
generated_table = File.read(File.join(root, NBS::TABLE_PATH))
check.call('the table file says it is generated', generated_table.include?('Generated by scripts/native_binding_split.rb'))

puts "\n#{failures.size} check(s) failed" unless failures.empty?
exit(failures.empty? ? 0 : 1)
