#!/usr/bin/env ruby
# encoding: UTF-8
#
# bc2cpp coverage report: regenerates tools/bc2cpp/bc2cpp.rb's whole-program
# diagnostic (every owner across all three compiled gems -- mruby-rpg2k-
# compiled/mruby-lcf-compiled/mruby-rgss-compiled -- combined, the same
# closed-world registry each real gem build feeds it) and prints a small,
# stats-only summary: compiled-entry-point and
# #error counts, a method-level coverage percentage (attempted vs. actually
# compiled clean), and both the resolved AND the poisoned-to-unknown side of
# every ivar/return/argument fact the diagnostic proves -- an "unknown"
# count that used to be silently dropped (ClassLayout's own analyze() only
# ever returned the resolved half; this script's own bc2cpp.rb change adds
# a `.known`/`.unknowns` split mirroring the one ArrayElementLayout already
# had, so the poisoned ivars are reportable too).
#
# Deliberately NOT the generated C++ itself: a single gem's own generated
# output runs past 250K lines, and even an unrelated bc2cpp.rb/mrblib edit
# can reshuffle register numbers and line order across the whole file --
# tracking that in git would make every commit's diff unreviewable and put
# any two concurrent bc2cpp-touching PRs into a guaranteed merge conflict in
# a file neither of them meaningfully changed. This report is the cheaper
# alternative: aggregate counts only, so the report can be published in the
# CI job summary and copied into a PR description without adding a generated
# file that conflicts whenever two concurrent bc2cpp changes land together.
# Contains no timestamp or other run-specific content.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp_coverage_report.rb
# Requires a host mrbc already built (3rd/mruby/build/host, the same
# prerequisite every real mruby-*-compiled/mrbgem.rake Rake task already
# has). Writes to stdout. Set BC2CPP_COVERAGE_REPORT_PATH to write a file
# instead (used by callers that need to capture the report).

require 'shellwords'
require 'open3'
require 'tmpdir'
require 'set'

ROOT = File.expand_path('..', __dir__)
require_relative '../tools/bc2cpp/compiled_gems'
require_relative '../tools/bc2cpp/symbol_cache'

BC2CPP = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')
MRBC = ENV['MRBC'] || 'mrbc'
# Optional output path for callers that need to capture the report.
REPORT_PATH = ENV['BC2CPP_COVERAGE_REPORT_PATH']

srcs = closed_world_mrblib_srcs(ROOT)
native_srcs = Dir["#{ROOT}/mruby-rgss/src/*.cxx"] + core_native_srcs("#{ROOT}/3rd/mruby") +
              external_gem_native_srcs(ROOT)
# INTEGER_CONSTANT_PROOF's own out-of-closed-world poison source -- see
# foreign_mrblib_srcs (compiled_gems.rb) and bc2cpp.rb's own IntegerConstants
# header. Passed here for the same reason NATIVE_SRCS is: this report must
# measure what a real gem build actually produces, and bc2cpp skips the whole
# analysis unless BOTH inputs are present.
foreign_ruby_srcs = foreign_mrblib_srcs(ROOT)
all_owners = BC2CPP_COMPILED_GEMS.values.flat_map { |g| g[:owners] }
# owner name -> gem short name, for the per-gem breakdown below.
gem_of_owner = {}
BC2CPP_COMPILED_GEMS.each { |gem, g| g[:owners].each { |o| gem_of_owner[o] = gem } }

env = {
  'MRBC' => MRBC,
  'OUT_SYMBOL' => 'coverage_report',
  'ONLY_OWNERS' => all_owners.join(','),
  'NATIVE_SRCS' => Shellwords.join(native_srcs),
  'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_ruby_srcs),
}
cmd = [RbConfig.ruby, BC2CPP, *srcs].shelljoin
Dir.mktmpdir do |dir|
  env['OUT_DIR'] = dir
  @stdout, @stderr, status = Open3.capture3(env, cmd)
  raise "bc2cpp.rb failed (exit #{status.exitstatus}):\n#{@stderr[-4000..]}" unless status.success?
end

# DYNAMIC_DISPATCH_STATS_SUPPORT: a second, SEPARATE run with SKIP_
# UNSUPPORTED=1 -- the real flag every actual gem build sets, dropping
# every method that still has a `#error` anywhere in its own body (see
# compile_all's own SKIP_UNSUPPORTED comment). The FIRST run above
# deliberately doesn't set it (this report's own #error-by-reason
# breakdown needs the real #error TEXT, which SKIP_UNSUPPORTED=1 strips
# out entirely) -- so counting `mrb_funcall`/`mrb_funcall_with_block`
# call sites straight off that first run's own @stdout would overcount:
# it would include real dispatch lines sitting inside a method that
# never actually ships, alongside its own unrelated #error. A second,
# real "what does the shipped build actually contain" run is the only
# way to get a true whole-program dynamic-dispatch count.
Dir.mktmpdir do |dir|
  shipped_env = env.merge('OUT_SYMBOL' => 'coverage_report_shipped', 'SKIP_UNSUPPORTED' => '1', 'OUT_DIR' => dir)
  @shipped_stdout, shipped_stderr, shipped_status = Open3.capture3(shipped_env, cmd)
  raise "bc2cpp.rb (SKIP_UNSUPPORTED=1) failed (exit #{shipped_status.exitstatus}):\n#{shipped_stderr[-4000..]}" unless shipped_status.success?
end

# ---------------------------------------------------------------------------
# Section counts, straight off bc2cpp.rb's own `== header ==` diagnostic --
# see that file's own `warn '== ... =='` call sites for the exact section
# list this depends on.
# ---------------------------------------------------------------------------
def section_lines(text, header)
  start = text.index("== #{header} ==")
  raise "section #{header.inspect} not found in bc2cpp.rb's own diagnostic" unless start

  rest = text[start..]
  stop = rest.index("\n==", 1)
  body = stop ? rest[0...stop] : rest
  body.lines.drop(1).map(&:strip).reject(&:empty?)
end

def count(text, header, placeholder: nil)
  lines = section_lines(text, header)
  return 0 if placeholder && lines == [placeholder]

  lines.size
end

err = @stderr

# `== compiled entry points ==` is every method compile_all produced an
# entry for -- but WITHOUT `SKIP_UNSUPPORTED=1` (this run's own default,
# needed below to see the real #error text at all) that list is
# unfiltered: it still includes a method whose body is nothing but
# `#error` lines (compile_all's own SKIP_UNSUPPORTED partition is what
# normally drops those, done here only when a real gem build sets the
# env var -- see that code's own comment). So this raw line count is
# "entries registered", not "entries that actually compiled" -- the
# method-level scan below re-derives the real clean/errored split by
# reading each entry's own generated body.
compiled_lines = section_lines(err, 'compiled entry points')
compiled_names = compiled_lines.filter_map { |l| (m = l.match(/\((\S+)#(\S+),/)) && "#{m[1]}##{m[2]}" }.to_set

never_called_match = err.match(/== never called \((\d+) of (\d+) compiled entry points/)

# ---------------------------------------------------------------------------
# Method-level coverage: every real bytecode method compile_method ever
# attempts gets its own `// Owner#name (compiled from irep N, M insns)`
# comment right before its `_impl` signature (compile_method's own
# unconditional header, emitted whether or not the body that follows is
# real code or nothing but #error lines) -- splitting @stdout on that
# marker gives one chunk per attempted method. A synthesized accessor
# override (ATTR_STRUCT_DEVIRT's own emit_synthesized_accessors, added to
# `compiled` alongside compile_all's own output) never goes through
# compile_method at all, so it carries no such comment and never appears
# here -- `compiled_names - attempted_names` below is exactly that set.
#
# Also the only place the real #error TEXT is visible at all (the stderr
# diagnostic never prints it, only counts derived from stdout can), so the
# per-reason breakdown further down reads the same @stdout this scan does.
# ---------------------------------------------------------------------------
attempted_names = Set.new
errored_names = Set.new
error_reasons = Hash.new(0)
@stdout.split(/^(?=\/\/ (\S+#\S+) \(compiled from irep \d+, \d+ insns\)$)/).drop(1).each_slice(2) do |name, chunk|
  attempted_names << name
  chunk.each_line do |line|
    m = line.match(/#error (.+?) -- not in this prototype/)
    next unless m

    errored_names << name
    # Collapse the per-call-site variable part of a splat/keyword-argument
    # error (arg/kwarg counts differ site to site) so the report buckets by
    # shape, not by exact signature -- everything else here is already a
    # fixed opcode name.
    reason = m[1].sub(/^SEND\/SSEND :\S+ /, 'SEND/SSEND ').sub(/\(n=[^)]*\)/, '(n=...)')
    error_reasons[reason] += 1
  end
end
total_errors = error_reasons.values.sum
attempted = attempted_names.size
errored = errored_names.size

clean_names = compiled_names - errored_names
synthesized_count = (compiled_names - attempted_names).size
compiled_by_gem = Hash.new(0)
clean_names.each do |name|
  owner = name.split('#', 2).first
  compiled_by_gem[gem_of_owner[owner] || 'unknown'] += 1
end

report = +''
report << "bc2cpp coverage report\n"
report << "(scripts/bc2cpp_coverage_report.rb; whole-program, all three compiled\n"
report << " gems' owners combined -- see that script's own header)\n\n"

report << "compiled entry points (real build output -- clean, zero #error): #{clean_names.size}\n"
report << "  from bytecode: #{clean_names.size - synthesized_count}\n"
report << "  synthesized accessor overrides (ATTR_STRUCT_DEVIRT): #{synthesized_count}\n"
compiled_by_gem.sort.each { |gem, n| report << "  #{gem}: #{n}\n" }
if never_called_match
  report << "never called (zero evidence in bytecode or NATIVE_SRCS): #{never_called_match[1]}\n"
end
report << "classes needing MRB_SET_INSTANCE_TT: #{count(err, 'classes needing MRB_SET_INSTANCE_TT(..., MRB_TT_DATA)')}\n"
report << "\n"

report << "-- method-level coverage (every bytecode method compile_method attempted) --\n"
report << "methods attempted: #{attempted}\n"
report << "  compiled clean: #{attempted - errored}\n"
report << "  left on the interpreter (>=1 #error): #{errored}\n"
report << format("  coverage: %.1f%%\n", attempted.zero? ? 0.0 : 100.0 * (attempted - errored) / attempted)
report << "\n"

report << "-- ivar/return/argument facts proven --\n"
report << "known-ivar-class hints (CLASS_HINT): #{count(err, 'known-ivar-class hints (devirtualization only, never embedded)', placeholder: '(none)')}\n"
report << "  poisoned to unknown (real evidence, but disagreeing/untraceable): #{count(err, 'ivar-class candidates (real SETIV evidence found, but poisoned to unknown)', placeholder: '(none)')}\n"
# ANY_OPAQUE_SUPPORT: the same poisoned-ivar-class count above, split by
# WHY -- :any (two real sites proven to genuinely disagree, unfixable) vs.
# :opaque (at least one site untraceable, a real candidate for a future
# annotation round). See ClassLayout.analyze's own `poison_reason` header.
report << "  split: ANY (proven heterogeneous, not fixable): #{count(err, 'ivar-class candidates split: ANY (proven heterogeneous, not fixable)', placeholder: '(none)')}\n"
report << "  split: OPAQUE (unresolved, may be fixable): #{count(err, 'ivar-class candidates split: OPAQUE (unresolved, may be fixable)', placeholder: '(none)')}\n"
report << "known-array-element-class hints (ELEM_HINT): #{count(err, 'known-array-element-class hints (guarded devirtualization only)', placeholder: '(none)')}\n"
# PRIMITIVE_ELEMENT_SUPPORT: element facts that resolved to a primitive
# scalar (Integer/Hash/String/Symbol) rather than a real registry class --
# never fed to CodeGen (see ArrayElementLayout.primitives' own comment),
# reported here purely so a resolved-but-inert primitive fact isn't
# invisible to the coverage trend.
report << "  primitive-only hints (never embedded): #{count(err, 'known-array-element PRIMITIVE hints (informational only, never embedded)', placeholder: '(none)')}\n"
report << "  poisoned to unknown (proven Array, element class unresolved): #{count(err, 'array-element candidates (proven-Array ivar, element class poisoned to unknown)', placeholder: '(none)')}\n"
report << "    split: ANY (proven heterogeneous, not fixable): #{count(err, 'array-element candidates split: ANY (proven heterogeneous, not fixable)', placeholder: '(none)')}\n"
report << "    split: OPAQUE (unresolved, may be fixable): #{count(err, 'array-element candidates split: OPAQUE (unresolved, may be fixable)', placeholder: '(none)')}\n"
report << "known-hash-element-class hints (HASH_ELEM_HINT): #{count(err, 'known-hash-element-class hints (guarded devirtualization only)', placeholder: '(none)')}\n"
report << "  primitive-only hints (never embedded): #{count(err, 'known-hash-element PRIMITIVE hints (informational only, never embedded)', placeholder: '(none)')}\n"
report << "  poisoned to unknown (proven Hash, value class unresolved): #{count(err, 'hash-element candidates (proven-Hash ivar, value class poisoned to unknown)', placeholder: '(none)')}\n"
report << "    split: ANY (proven heterogeneous, not fixable): #{count(err, 'hash-element candidates split: ANY (proven heterogeneous, not fixable)', placeholder: '(none)')}\n"
report << "    split: OPAQUE (unresolved, may be fixable): #{count(err, 'hash-element candidates split: OPAQUE (unresolved, may be fixable)', placeholder: '(none)')}\n"
report << "ivar embedding (EMBED): #{count(err, 'ivar embedding', placeholder: '(none embeddable)')}\n"
report << "magic-comment return annotations (ANNOTATED): #{count(err, 'magic-comment annotations (# bc2cpp: (T, ...) -> T)', placeholder: '(none found)')}\n"
report << "magic-comment class-argument annotations (CLASS_ANNOTATED): #{count(err, 'magic-comment class annotations (# bc2cpp: (ClassName, ...))', placeholder: '(none found)')}\n"
report << "magic-comment element annotations (ELEM_ANNOTATED): #{count(err, 'magic-comment element annotations (# bc2cpp: ... -> Array<Klass> / -> Klass)', placeholder: '(none found)')}\n"
report << "annotation candidates (opaque argument, unresolved): #{count(err, 'annotation candidates (opaque incoming argument, unresolved)', placeholder: '(none)')}\n"
# INTEGER_CONSTANT_PROOF: bare constant names every definition in the whole
# program agrees is an integer literal -- FIXNUM_OPERAND_PROOF's own fifth
# proof source. Reported here for the same reason every other proven fact
# above is: it is a real, whole-program fact whose count moves when the Ruby
# sources change (a new `FOO = 3` adds one; reassigning an existing constant
# to a non-literal silently REMOVES one, along with every devirtualization it
# was feeding), so a drift in it is exactly the kind of thing this file's own
# git diff exists to make visible.
report << "integer-valued constants proven (INTEGER_CONSTANT_PROOF): #{count(err, 'integer-valued constants proven (INTEGER_CONSTANT_PROOF)', placeholder: '(none)')}\n"
# UNIQUE_CLASS_NAME: bare class names canonicalized to their one definition.
report << "bare class names with one definition (UNIQUE_CLASS_NAME): #{count(err, 'bare class names with one definition (UNIQUE_CLASS_NAME)')}\n"
# FIXNUM_RETURN_PROOF: bare method names whose one closed-world definition
# provably returns a Fixnum on every return path -- FIXNUM_OPERAND_PROOF's
# own sixth proof source. Tracked here for exactly the reason the constant
# count above is: it is a whole-program fact that moves silently when the
# Ruby sources change. Adding a `return nil` guard to one of these methods,
# or a second definition of its bare name anywhere (including in mruby's own
# mrblib), removes the name and with it every devirtualization it fed.
report << "methods proven Fixnum-returning (FIXNUM_RETURN_PROOF): #{count(err, 'methods proven Fixnum-returning (FIXNUM_RETURN_PROOF)', placeholder: '(none)')}\n"
# ARRAY_RETURN_PROOF: the Array analogue of the line just above -- bare
# method names whose one closed-world definition provably returns an Array
# on every return path, consumed by the block recognizers' own receiver gate
# (proven_array_source). Tracked here for the identical reason: it is a
# whole-program fact that moves silently when the Ruby sources change. An
# added `return nil` guard, a new conditional landing on a method's own
# RETURN, or a second definition of its bare name anywhere (including in
# mruby's own mrblib) removes the name and with it every loop it unblocked.
report << "methods proven Array-returning (ARRAY_RETURN_PROOF): #{count(err, 'methods proven Array-returning (ARRAY_RETURN_PROOF)', placeholder: '(none)')}\n"
report << "\n"

report << "-- #error markers by reason (whole program) --\n"
error_reasons.sort_by { |reason, n| [-n, reason] }.each do |reason, n|
  report << format("  %5d  %s\n", n, reason)
end
report << format("  %5d  total\n", total_errors)
report << "\n"

# BLOCK_CFUNC_FALLBACK_SUPPORT: a previously-#error'd BLOCK/SENDB/SSENDB
# call site that now compiles clean via emit_block_fallback_glue's own
# `// BLOCK_FALLBACK :name -- ...` marker comment -- these already count
# toward "compiled clean" above, same as any other method, but are
# deliberately ALSO broken out here because the call carrying the block
# still dispatches dynamically (`mrb_funcall_with_block`). The standalone
# cfunc body can now specialize calls on proven Array/Hash iterator elements, so
# count those separately from the dynamic block-carrying call site.
block_fallback_count = @stdout.scan(/^\s*\/\/ BLOCK_FALLBACK :/).size
report << "block bodies compiled via cfunc/RProc fallback (BLOCK_FALLBACK): " \
          "#{block_fallback_count}\n"
fallback_element_sends = Hash.new(0)
current_fallback = nil
@stdout.each_line do |line|
  if (m = line.match(/^\s*(?:static )?mrb_value (\w*block_fallback\w*_impl)\(.*\) \{\s*$/))
    current_fallback = m[1]
    fallback_element_sends[current_fallback] ||= 0
  elsif line.match?(/^\s*(?:static )?mrb_value \w+\(.*\) \{\s*$/)
    current_fallback = nil
  elsif current_fallback && line.include?('// ELEMENT :')
    fallback_element_sends[current_fallback] += 1
  end
end
fallback_element_functions = fallback_element_sends.count { |_name, sends| sends.positive? }
fallback_element_send_count = fallback_element_sends.values.sum
report << "  fallback cfuncs with guarded Array/Hash iterator element sends: " \
          "#{fallback_element_functions} function(s), #{fallback_element_send_count} send(s)\n"

# LAMBDA_FALLBACK_SUPPORT: the LAMBDA-opcode sibling of BLOCK_CFUNC_
# FALLBACK_SUPPORT immediately above -- a previously-#error'd LAMBDA
# instruction that now compiles clean via emit_lambda_fallback_glue's own
# `// LAMBDA_FALLBACK -- ...` marker comment. Counted the same way, but
# deliberately NOT captioned "dynamic dispatch": a LAMBDA never calls
# anything itself (it only BUILDS a value), so there is no dispatch
# decision to make at the LAMBDA site at all -- whatever devirtualization
# coverage applies to a LATER `.call`/`.()` on the resulting value is
# already whatever compile_send's own MONO/POLY/TYPED logic decides for
# that separate call site (an opaque-Proc receiver, so POLY/dynamic in
# practice today, same as any other not-statically-known receiver).
lambda_fallback_count = @stdout.scan(/^\s*\/\/ LAMBDA_FALLBACK --/).size
report << "lambda bodies compiled via cfunc/RProc fallback (LAMBDA_FALLBACK): " \
          "#{lambda_fallback_count}\n"
sdef_fallback_count = @stdout.scan(/^\s*\/\/ SDEF_FALLBACK :/).size
tdef_fallback_count = @stdout.scan(/^\s*\/\/ TDEF_FALLBACK :/).size
sclass_fallback_count = @stdout.scan(/^\s*\/\/ SCLASS_FALLBACK \+/).size
report << "runtime definition fallbacks (SDEF/TDEF/SCLASS+EXEC): " \
          "#{sdef_fallback_count}/#{tdef_fallback_count}/#{sclass_fallback_count}\n"
report << "\n"

# DYNAMIC_DISPATCH_STATS_SUPPORT: every real dynamic-dispatch call site
# left in the actual SHIPPED build (@shipped_stdout, SKIP_UNSUPPORTED=1
# -- see its own capture comment above). The generator's SymbolCache rewrites
# the ordinary mrb_funcall form to `bc2cpp_send(M, recv, index, ...)`; resolve
# those indices through the generated symbol table instead of scanning only the
# pre-cache spelling. `mrb_funcall_with_block` is counted separately because it
# carries a block and is emitted by the block-fallback glue, not SymbolCache.
def unescape_cpp_string(s)
  s.gsub(/\\x(\h\h)/) { [Regexp.last_match(1).hex].pack('C') }
    .gsub(/\\([0-7]{1,3})/) { Regexp.last_match(1).to_i(8).chr }
    .gsub(/\\(.)/) { { 'n' => "\n", 't' => "\t", 'r' => "\r" }.fetch(Regexp.last_match(1), Regexp.last_match(1)) }
end

def cached_send_indices(code)
  indices = []
  pos = 0
  while (start = code.index(/\bbc2cpp_send\(M,\s*/, pos))
    head_end = Regexp.last_match.end(0)
    receiver_end = SymbolCache.expression_end(code, head_end)
    index = receiver_end && code[receiver_end..][/\A,\s*(\d+)\s*[,)]/, 1]
    indices << index.to_i if index
    pos = start + 1
  end
  indices
end

def cached_with_block_indices(code)
  indices = []
  pos = 0
  while (start = code.index(/\bmrb_funcall_with_block\(M,\s*/, pos))
    head_end = Regexp.last_match.end(0)
    receiver_end = SymbolCache.expression_end(code, head_end)
    index = receiver_end && code[receiver_end..][/\A,\s*bc2cpp_sym\(M,\s*(\d+)\)\s*[,)]/, 1]
    indices << index.to_i if index
    pos = start + 1
  end
  indices
end

dispatch_counts = Hash.new(0)
symbol_names = @shipped_stdout[/static const char\* const bc2cpp_sym_names\[\d+\] = \{(.*?)\n\};/m, 1].to_s
                         .scan(/"((?:[^"\\\n]|\\.)*)"/).flatten.map { |literal| unescape_cpp_string(literal) }
(cached_send_indices(@shipped_stdout) + cached_with_block_indices(@shipped_stdout)).each do |index|
  name = symbol_names[index]
  dispatch_counts[name || "?symbol-#{index}"] += 1
end
@shipped_stdout.scan(/mrb_funcall_with_block\(M,\s*[^,]+,\s*mrb_intern_cstr\(M,\s*"((?:[^"\\]|\\.)*)"\)/) { |m| dispatch_counts[unescape_cpp_string(m[0])] += 1 }
total_dispatch = dispatch_counts.values.sum
shipped_poly = @shipped_stdout.scan(/^\s*\/\/ POLY :\S+ --/).size
raise "bc2cpp coverage report: POLY markers exceed dispatch sites" if shipped_poly > total_dispatch
hash_values_fast_paths = @shipped_stdout.scan(/^\s*\/\/ HASH_VALUES :values/).size

report << "-- dynamic dispatch remaining (real shipped build, SKIP_UNSUPPORTED=1) --\n"
report << "total cached bc2cpp_send/mrb_funcall_with_block call sites: #{total_dispatch}\n"
report << "  POLY-marked (receiver's runtime class genuinely decides): #{shipped_poly}\n"
report << "  guarded native Hash#values call sites: #{hash_values_fast_paths}\n"
report << "  everything else (not yet attempted or failed MONO/TYPED): #{[total_dispatch - shipped_poly, 0].max}\n"
report << "distinct dynamically-dispatched method names: #{dispatch_counts.size}\n"
report << "top 30 dynamically-dispatched method names:\n"
dispatch_counts.sort_by { |name, n| [-n, name] }.first(30).each_with_index do |(name, n), i|
  report << format("  %2d. %5d  :%s\n", i + 1, n, name)
end

if REPORT_PATH
  File.write(REPORT_PATH, report)
else
  puts report
end
