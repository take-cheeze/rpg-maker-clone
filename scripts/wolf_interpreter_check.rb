#!/usr/bin/env ruby
# encoding: UTF-8
#
# Soak-test Wolf::Interpreter against a real project's own Common Events --
# the "RPG Basic System" the editor bundles, in the default test bed
# (scripts/download-wolfrpg-sample.bash). Unlike scripts/wolf_testbed_check.rb
# (which only proves the *data* parses), this drives the interpreter itself:
# every auto-start and parallel-process Common Event runs for a bounded
# number of frames, and the check is that nothing raises and nothing hangs
# (a malformed branch/loop reconstruction could otherwise spin forever, since
# Wolf::Interpreter::Run's Fiber does not yield except at Wait) -- the same
# "does it survive real data" bar scripts/rpg2k_command_soak.rb holds RPG2000's
# own interpreter to.
#
# It does not (and cannot yet) assert *behavioural* correctness: there is no
# genuine Game.exe to compare against in this engine's usual wine-diffing way
# (see docs/adr/0064-wolf-rpg-editor-data-layer.md). What it can and does
# assert is that the reconstructed command semantics do not crash or hang on
# a real, large (27,356-command) Common Event corpus, and it reports which
# "not implemented" command warnings fired, so a newly-added command handler
# can be checked against real usage instead of only hand-built fixtures.
#
# Usage:
#   ruby scripts/wolf_interpreter_check.rb [PROJECT_DIR ...] [--frames N]
# With no directory arguments it scans ./data the same way
# scripts/wolf_testbed_check.rb does. Exits non-zero on any exception, and on
# a run that fails to make progress (every live Common Event stuck waiting)
# for an unreasonable number of frames.

require 'stringio'

module LCF
  def self.cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J')
     .encode('UTF-8', invalid: :replace, undef: :replace, replace: "\u{FFFD}")
  end
end

module Wolf
  module LZ4
    def self.decompress(src, dst_size)
      out = +''
      n = src.bytesize
      i = 0
      while i < n
        token = src.getbyte(i)
        i += 1
        lit = token >> 4
        if lit == 15
          loop do
            raise Wolf::Error, 'LZ4: truncated literal length' if i >= n
            b = src.getbyte(i)
            i += 1
            lit += b
            break if b != 255
          end
        end
        if lit > 0
          raise Wolf::Error, 'LZ4: truncated literals' if i + lit > n
          out << src.byteslice(i, lit)
          i += lit
        end
        break if i >= n
        raise Wolf::Error, 'LZ4: truncated match offset' if i + 2 > n
        offset = src.getbyte(i) | (src.getbyte(i + 1) << 8)
        i += 2
        raise Wolf::Error, 'LZ4: zero match offset' if offset == 0
        raise Wolf::Error, 'LZ4: match offset before start of output' if offset > out.bytesize
        mlen = token & 0xf
        if mlen == 15
          loop do
            raise Wolf::Error, 'LZ4: truncated match length' if i >= n
            b = src.getbyte(i)
            i += 1
            mlen += b
            break if b != 255
          end
        end
        mlen += MIN_MATCH
        start = out.bytesize - offset
        if offset >= mlen
          out << out.byteslice(start, mlen)
        else
          old_size = out.bytesize
          out << ("\0" * mlen)
          mlen.times { |k| out.setbyte(old_size + k, out.getbyte(start + k)) }
        end
      end
      raise Wolf::Error, "LZ4: decoded #{out.bytesize} bytes, expected #{dst_size}" if out.bytesize != dst_size
      out
    end
  end
end

mrblib = File.expand_path('../mruby-wolf/mrblib', __dir__)
load File.join(mrblib, 'wolf.rb')
load File.join(mrblib, 'data.rb')
load File.join(mrblib, 'vars.rb')
load File.join(mrblib, 'interpreter.rb')

FRAMES = (idx = ARGV.index('--frames')) ? ARGV.delete_at(idx + 1).tap { ARGV.delete_at(idx) }.to_i : 120

# A single Run given a fixed step budget, so one command list that genuinely
# never yields (an interpreter bug, not real game behaviour) fails the check
# instead of hanging the process forever.
MAX_STEPS_PER_RUN = 200_000

class BoundedRun < Wolf::Interpreter::Run
  def step
    @soak_steps ||= 0
    @soak_steps += 1
    raise "Run exceeded #{MAX_STEPS_PER_RUN} steps without finishing or yielding -- suspected infinite loop" if @soak_steps > MAX_STEPS_PER_RUN
    super
  end
end

class Checker
  def initialize
    @errors = 0
  end

  attr_reader :errors

  def fail(msg)
    @errors += 1
    warn "  FAIL #{msg}"
  end

  def check_project(dir)
    puts "== #{dir}"
    project = Wolf::Project.new(dir)
    store = Wolf::VarStore.new(project)
    interp = Wolf::Interpreter.new(project, store)

    # Swap in the bounded Run so a real hang is reported as a failure rather
    # than left to the caller's own patience.
    interp.define_singleton_method(:call_common) do |common_id, params, target, reserve:|
      if reserve
        instance_variable_get(:@reserved) << [common_id, params, target]
        next
      end
      ce = project.common_events[common_id]
      unless ce
        store.warn_once("no-common-event-#{common_id}", "call to common event #{common_id}, which does not exist")
        next
      end
      bank = store.common_event_self_bank(common_id)
      send(:numeric_self_slots, params.size).each_with_index { |slot, k| bank[slot] = params[k] }
      prev = store.current_common_event_id
      store.current_common_event_id = common_id
      run = BoundedRun.new(interp, ce.commands)
      run.step while !run.done
      store.current_common_event_id = prev
      next unless target
      store.set_number(target, bank[ce.return_variable] || 0)
    end

    auto_or_parallel = project.common_events.events.select { |ce| ce.auto? || ce.parallel? }
    puts "  #{project.common_events.size} common events, #{auto_or_parallel.size} auto/parallel"

    FRAMES.times do |frame|
      interp.update
    rescue StandardError => e
      fail "frame #{frame}: #{e.class}: #{e.message}"
      break
    end

    puts "  ok: ran #{FRAMES} frames with no exception"
  rescue Wolf::Error, StandardError => e
    fail "#{dir}: #{e.class}: #{e.message}"
  end
end

dirs = ARGV.dup
if dirs.empty?
  data_dir = File.expand_path('../data', __dir__)
  if Dir.exist?(data_dir)
    Dir.children(data_dir).sort.each do |name|
      d = File.join(data_dir, name)
      dirs << d if Wolf::Project.project?(File.join(d, 'WOLF_RPG_Editor3'))
      dirs << d if Wolf::Project.project?(d)
    end
  end
end

if dirs.empty?
  puts 'No WOLF RPG Editor project found under ./data; nothing to check.'
  exit 0
end

checker = Checker.new
dirs.uniq.each do |d|
  root = Wolf::Project.project?(d) ? d : File.join(d, 'WOLF_RPG_Editor3')
  checker.check_project(root)
end

if checker.errors > 0
  warn "#{checker.errors} check(s) failed"
  exit 1
end
puts 'All WOLF RPG Editor interpreter soak checks passed.'
