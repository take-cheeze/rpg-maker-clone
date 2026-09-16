#!/usr/bin/env ruby
# encoding: UTF-8
#
# bc2cpp coverage report: regenerates tools/bc2cpp/bc2cpp.rb's whole-program
# diagnostic (every owner across all three compiled gems -- mruby-rpg2k-
# compiled/mruby-lcf-compiled/mruby-rgss-compiled -- combined, the same
# closed-world registry each real gem build feeds it) and writes a small,
# stats-only summary to docs/bc2cpp_coverage.txt: compiled-entry-point and
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
# alternative: aggregate counts only, so `git diff docs/bc2cpp_coverage.txt`
# shows a real, measured coverage change (more/fewer compiled entry points,
# a shrinking #error total, a new class of proven ivar-class hint), not
# codegen noise. Contains no timestamp or other run-specific content, so
# regenerating with no real source change produces an empty diff.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp_coverage_report.rb
# Requires a host mrbc already built (3rd/mruby/build/host, the same
# prerequisite every real mruby-*-compiled/mrbgem.rake Rake task already
# has). Writes docs/bc2cpp_coverage.txt in place -- review the diff and
# commit it alongside whatever bc2cpp.rb/mrblib change produced it.

require 'shellwords'
require 'open3'
require 'tmpdir'
require 'set'

ROOT = File.expand_path('..', __dir__)
require_relative '../tools/bc2cpp/compiled_gems'

BC2CPP = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')
MRBC = ENV['MRBC'] || 'mrbc'
REPORT_PATH = File.join(ROOT, 'docs/bc2cpp_coverage.txt')

srcs = closed_world_mrblib_srcs(ROOT)
native_srcs = Dir["#{ROOT}/mruby-rgss/src/*.cxx"] + core_native_srcs("#{ROOT}/3rd/mruby") +
              external_gem_native_srcs(ROOT)
all_owners = BC2CPP_COMPILED_GEMS.values.flat_map { |g| g[:owners] }
# owner name -> gem short name, for the per-gem breakdown below.
gem_of_owner = {}
BC2CPP_COMPILED_GEMS.each { |gem, g| g[:owners].each { |o| gem_of_owner[o] = gem } }

env = {
  'MRBC' => MRBC,
  'OUT_SYMBOL' => 'coverage_report',
  'ONLY_OWNERS' => all_owners.join(','),
  'NATIVE_SRCS' => Shellwords.join(native_srcs),
}
cmd = [RbConfig.ruby, BC2CPP, *srcs].shelljoin
Dir.mktmpdir do |dir|
  env['OUT_DIR'] = dir
  @stdout, @stderr, status = Open3.capture3(env, cmd)
  raise "bc2cpp.rb failed (exit #{status.exitstatus}):\n#{@stderr[-4000..]}" unless status.success?
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
report << "known-array-element-class hints (ELEM_HINT): #{count(err, 'known-array-element-class hints (guarded devirtualization only)', placeholder: '(none)')}\n"
report << "  poisoned to unknown (proven Array, element class unresolved): #{count(err, 'array-element candidates (proven-Array ivar, element class poisoned to unknown)', placeholder: '(none)')}\n"
report << "ivar embedding (EMBED): #{count(err, 'ivar embedding', placeholder: '(none embeddable)')}\n"
report << "magic-comment return annotations (ANNOTATED): #{count(err, 'magic-comment annotations (# bc2cpp: (T, ...) -> T)', placeholder: '(none found)')}\n"
report << "magic-comment class-argument annotations (CLASS_ANNOTATED): #{count(err, 'magic-comment class annotations (# bc2cpp: (ClassName, ...))', placeholder: '(none found)')}\n"
report << "magic-comment element annotations (ELEM_ANNOTATED): #{count(err, 'magic-comment element annotations (# bc2cpp: ... -> Array<Klass> / -> Klass)', placeholder: '(none found)')}\n"
report << "annotation candidates (opaque argument, unresolved): #{count(err, 'annotation candidates (opaque incoming argument, unresolved)', placeholder: '(none)')}\n"
report << "\n"

report << "-- #error markers by reason (whole program) --\n"
error_reasons.sort_by { |reason, n| [-n, reason] }.each do |reason, n|
  report << format("  %5d  %s\n", n, reason)
end
report << format("  %5d  total\n", total_errors)

File.write(REPORT_PATH, report)
puts "wrote #{REPORT_PATH}"
