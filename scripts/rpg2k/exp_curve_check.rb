#!/usr/bin/env ruby
# frozen_string_literal: true

# Holds Game.exp_curve's C loop (mruby-rpg2k/src/exp_curve.hxx, on double: mrb_float on every target) to the Ruby
# Float loop it replaced (scripts/rpg2k/native_stand_ins.rb) for every exp_basic, exp_increase and exp_correction in
# 0..100 (a superset of the editors' ranges) and every n in 0..99 at the RPG2000 cap, plus out-of-range rows.
# Needs a C++17 compiler ($CXX, default c++; $CXXFLAGS is added, e.g. -mfma to try an FMA target).
#
#   ruby scripts/rpg2k/exp_curve_check.rb [--jobs N] [--basic-step N]
#
# --basic-step N sweeps every Nth exp_basic only (the coverage reporter's run, where the Ruby loop is about 7x slower).

require 'etc'
require 'open3'
require 'optparse'
require 'tmpdir'
require_relative 'native_stand_ins'

ROOT = File.expand_path('../..', __dir__)
CXX = ENV.fetch('CXX', 'c++')
RANGE = (0..100).freeze
LEVELS = (0..99).freeze
CAP = 999_999 # Game::Actor::EXP_MAX_2K

jobs = Etc.nprocessors
basic_step = 1
OptionParser.new do |o|
  o.on('--jobs N', Integer) { |n| jobs = n }
  o.on('--basic-step N', Integer) { |n| basic_step = n }
end.parse!

HARNESS = <<~CXX
  #include <cstdio>
  #include <cstdlib>
  #include "exp_curve.hxx"
  // sweep B: every increase, correction in 0..100 and n in 0..99 at cap #{CAP}, as int32 values.
  // rows: "basic increase correction n cap" lines in, "ok VALUE" / "overflow" lines out.
  int main(int argc, char** argv) {
    if (argc == 3) {
      const long long b = std::atoll(argv[2]);
      for (int inc = #{RANGE.min}; inc <= #{RANGE.max}; ++inc)
        for (int c = #{RANGE.min}; c <= #{RANGE.max}; ++c)
          for (int n = #{LEVELS.min}; n <= #{LEVELS.max}; ++n) {
            const auto r = rpg2k::exp_curve_loop<double>(b, inc, c, n, #{CAP});
            const int v = r.status == rpg2k::ExpCurveStatus::ok ? static_cast<int>(r.value) : -1;
            std::fwrite(&v, sizeof v, 1, stdout);
          }
      return 0;
    }
    long long b, inc, c, n, cap;
    while (std::scanf("%lld %lld %lld %lld %lld", &b, &inc, &c, &n, &cap) == 5) {
      const auto r = rpg2k::exp_curve_loop<double>(b, inc, c, n, cap);
      if (r.status == rpg2k::ExpCurveStatus::ok) std::printf("ok %lld\\n", static_cast<long long>(r.value));
      else std::printf("overflow\\n");
    }
    return 0;
  }
CXX

# Out-of-range and default rows: EXP_DEFAULT (30), negative and huge fields, levels past 99, other caps.
EXTRA_ROWS = [
  [30, 30, 30, 0, CAP], [30, 30, 30, 1, CAP], [30, 30, 30, 98, CAP], [30, 30, 30, 49, 9_999_999],
  [10, 10, 0, 99, CAP], [50, 50, 40, 99, CAP], [0, 0, 0, 99, CAP], [100, 0, 0, 5, CAP],
  [30, 30, 30, 120, CAP], [30, 30, 30, 1000, CAP], [30, 30, 30, -1, CAP], [1, 0, 0, 500, CAP],
  [30, 30, 30, 50, 0], [30, 30, 30, 50, 1], [30, 30, 30, 99, 0x7fff_ffff], [0, 0, 0, 1000, 0x7fff_ffff],
  [-1, 30, 30, 50, CAP], [30, 30, -1, 50, CAP], [30, -1, 30, 50, CAP], [-30, -30, -30, 50, CAP],
  [30, -50, 30, 99, CAP], [30, -51, 30, 99, CAP], [30, -60, 30, 99, CAP], [30, -150, 30, 99, CAP],
  [30, -250, 30, 99, CAP], [1000, -60, 0, 99, CAP], [0, 30, -1000, 99, CAP], [-100, 50, 0, 99, CAP],
  [-1000, 100, 0, 99, CAP], [-1_000_000, 100, 0, 99, CAP], [-1_000_000, 1000, 0, 99, CAP],
  [-1_000_000, 10_000, 0, 99, CAP], [1_000_000, 30, 30, 99, CAP], [0x7fff_ffff, 0x7fff_ffff, 0x7fff_ffff, 99, CAP],
  [0x7fff_ffff, 30, -0x8000_0000, 2, CAP], [-0x8000_0000, 30, 30, 3, CAP],
  [-1_000_000, 1_000_000, 0, 1000, CAP], [-0x8000_0000, -0x8000_0000, -0x8000_0000, 99, CAP]
].freeze
# The C loop stops with overflow where the Ruby one needs an Integer past 64 bits (a Bignum on the host, a RangeError on
# the 32-bit builds). These rows pass 64 bits on the way to a result that fits.
OVERFLOW_ROWS = [[30, 30, -0x8000_0000, 99, 9_999_999]].freeze

INT64 = (-0x8000_0000_0000_0000..0x7fff_ffff_ffff_ffff).freeze

def expected(row)
  return %w[overflow] if OVERFLOW_ROWS.include?(row)

  v = Game.exp_curve(*row)
  INT64.cover?(v) ? ['ok', v.to_s] : %w[overflow]
# Float#to_i on an infinite term: the total passed 64 bits on an earlier step.
rescue FloatDomainError
  %w[overflow]
end

failures = []
Dir.mktmpdir('exp_curve_check') do |dir|
  src = File.join(dir, 'harness.cxx')
  bin = File.join(dir, 'harness')
  File.write(src, HARNESS)
  _out, err, st = Open3.capture3(CXX, '-std=c++17', '-O2', *ENV.fetch('CXXFLAGS', '').split,
                                  '-I', File.join(ROOT, 'mruby-rpg2k/src'), '-o', bin, src)
  abort "exp_curve check: #{CXX} failed:\n#{err}" unless st.success?

  # Every editor input, split by exp_basic over forked workers; each reports its mismatches on a pipe.
  per_basic = RANGE.size * RANGE.size * LEVELS.size
  queue = RANGE.step(basic_step).to_a
  workers = Array.new([jobs, 1].max) do |w|
    rd, wr = IO.pipe
    pid = fork do
      rd.close
      bad = []
      queue.each_with_index do |b, k|
        next unless k % jobs == w

        out, st = Open3.capture2(bin, 'sweep', b.to_s, binmode: true)
        values = out.unpack('l<*')
        unless st.success? && values.size == per_basic
          bad << "basic=#{b}: harness exited #{st.exitstatus} with #{values.size} of #{per_basic} values"
          next
        end
        idx = 0
        RANGE.each do |inc|
          RANGE.each do |c|
            LEVELS.each do |n|
              want = Game.exp_curve(b, inc, c, n, CAP)
              bad << "#{[b, inc, c, n, CAP].inspect}: C #{values[idx]}, Ruby #{want}" if values[idx] != want
              idx += 1
            end
          end
        end
      end
      wr.write(Marshal.dump(bad))
      wr.close
      exit!(0)
    end
    wr.close
    [pid, rd]
  end
  workers.each do |pid, rd|
    bad = Marshal.load(rd.read)
    rd.close
    _, st = Process.wait2(pid)
    failures << "worker #{pid} exited #{st.exitstatus}" unless st.success?
    failures.concat(bad)
  end
  basics = basic_step == 1 ? '0..100' : "0..100 step #{basic_step}"
  puts "  #{failures.empty? ? 'ok  ' : 'FAIL'} #{queue.size * per_basic} editor-range cases (basic #{basics}; " \
       'increase, correction 0..100; n 0..99)'

  rows = EXTRA_ROWS + OVERFLOW_ROWS
  out, st = Open3.capture2(bin, stdin_data: rows.map { |r| r.join(' ') }.join("\n"))
  abort "exp_curve check: harness exited #{st.exitstatus} on the extra rows" unless st.success?
  got = out.lines.map(&:split)
  extra_bad = []
  rows.each_with_index do |row, i|
    want = expected(row)
    extra_bad << "#{row.inspect}: C #{got[i].inspect}, Ruby #{want.inspect}" unless got[i] == want
  end
  puts "  #{extra_bad.empty? ? 'ok  ' : 'FAIL'} #{rows.size} out-of-range and default rows"
  failures.concat(extra_bad)
end

unless failures.empty?
  warn "exp_curve check: #{failures.size} mismatch(es)"
  failures.first(20).each { |f| warn "  #{f}" }
  exit 1
end
puts 'exp_curve check: the C loop matches the Ruby one'
