#!/usr/bin/env ruby
# encoding: UTF-8
#
# bc2cpp coverage report: regenerates tools/bc2cpp/bc2cpp.rb's whole-program
# diagnostic (every owner across all three compiled gems -- mruby-rpg2k-
# compiled/mruby-lcf-compiled/mruby-rgss-compiled -- combined, the same
# closed-world registry each real gem build feeds it) and writes a small,
# stats-only summary to docs/bc2cpp_coverage.txt.
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

compiled_lines = section_lines(err, 'compiled entry points')
compiled_by_gem = Hash.new(0)
compiled_lines.each do |line|
  owner = line[/\((\S+)#/, 1]
  compiled_by_gem[gem_of_owner[owner] || 'unknown'] += 1
end

never_called_match = err.match(/== never called \((\d+) of (\d+) compiled entry points/)

# ---------------------------------------------------------------------------
# #error marker breakdown -- only ever visible in the actual generated
# output (SKIP_UNSUPPORTED=0's own default, run above), never in the stderr
# diagnostic alone. Counted here and immediately discarded; the ~250K-line
# @stdout itself never touches disk beyond process memory.
# ---------------------------------------------------------------------------
error_reasons = Hash.new(0)
@stdout.each_line do |line|
  m = line.match(/#error (.+?) -- not in this prototype/)
  next unless m

  # Collapse the per-call-site variable part of a splat/keyword-argument
  # error (arg/kwarg counts differ site to site) so the report buckets by
  # shape, not by exact signature -- everything else here is already a
  # fixed opcode name.
  reason = m[1].sub(/^SEND\/SSEND :\S+ /, 'SEND/SSEND ').sub(/\(n=[^)]*\)/, '(n=...)')
  error_reasons[reason] += 1
end
total_errors = error_reasons.values.sum

report = +''
report << "bc2cpp coverage report\n"
report << "(scripts/bc2cpp_coverage_report.rb; whole-program, all three compiled\n"
report << " gems' owners combined -- see that script's own header)\n\n"

report << "compiled entry points: #{compiled_lines.size}\n"
compiled_by_gem.sort.each { |gem, n| report << "  #{gem}: #{n}\n" }
if never_called_match
  report << "never called (zero evidence in bytecode or NATIVE_SRCS): #{never_called_match[1]}\n"
end
report << "classes needing MRB_SET_INSTANCE_TT: #{count(err, 'classes needing MRB_SET_INSTANCE_TT(..., MRB_TT_DATA)')}\n"
report << "\n"

report << "-- ivar/return/argument facts proven --\n"
report << "known-ivar-class hints (CLASS_HINT): #{count(err, 'known-ivar-class hints (devirtualization only, never embedded)', placeholder: '(none)')}\n"
report << "known-array-element-class hints (ELEM_HINT): #{count(err, 'known-array-element-class hints (guarded devirtualization only)', placeholder: '(none)')}\n"
report << "ivar embedding (EMBED): #{count(err, 'ivar embedding', placeholder: '(none embeddable)')}\n"
report << "magic-comment return annotations (ANNOTATED): #{count(err, 'magic-comment annotations (# bc2cpp: (T, ...) -> T)', placeholder: '(none found)')}\n"
report << "magic-comment class-argument annotations (CLASS_ANNOTATED): #{count(err, 'magic-comment class annotations (# bc2cpp: (ClassName, ...))', placeholder: '(none found)')}\n"
report << "magic-comment element annotations (ELEM_ANNOTATED): #{count(err, 'magic-comment element annotations (# bc2cpp: ... -> Array<Klass> / -> Klass)', placeholder: '(none found)')}\n"
report << "array-element candidates (proven Array, element class unknown): #{count(err, 'array-element candidates (proven-Array ivar, element class poisoned to unknown)', placeholder: '(none)')}\n"
report << "annotation candidates (opaque argument, unresolved): #{count(err, 'annotation candidates (opaque incoming argument, unresolved)', placeholder: '(none)')}\n"
report << "\n"

report << "-- #error markers by reason (whole program) --\n"
error_reasons.sort_by { |reason, n| [-n, reason] }.each do |reason, n|
  report << format("  %5d  %s\n", n, reason)
end
report << format("  %5d  total\n", total_errors)

File.write(REPORT_PATH, report)
puts "wrote #{REPORT_PATH}"
