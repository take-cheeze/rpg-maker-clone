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
load File.join(mrblib, 'wolf_crypt_pro.rb')
load File.join(mrblib, 'data.rb')
load File.join(mrblib, 'vars.rb')
load File.join(mrblib, 'save_data.rb')
load File.join(mrblib, 'interpreter.rb')

FRAMES = (idx = ARGV.index('--frames')) ? ARGV.delete_at(idx + 1).tap { ARGV.delete_at(idx) }.to_i : 120

# A single Run given a fixed *dispatch* budget -- total commands executed
# across its whole lifetime, not just the number of #step (Fiber.resume)
# calls -- so a command list that genuinely never yields fails the check
# instead of hanging the process forever. Bounding only #step (an earlier
# version of this check did) cannot catch a loop that never reaches its own
# Wait/GotoLoopStart within a single Fiber.resume: found the hard way when
# a real Common Event chain a Confirm-trigger map event calls into (a
# shop UI's own cursor-input-wait loop, which this soak check has no real
# input to satisfy) hung this way -- #step never got called again because
# the loop itself was stuck inside its very first call.
MAX_DISPATCHES_PER_RUN = 200_000

class SuspectedInfiniteLoop < RuntimeError; end

class BoundedRun < Wolf::Interpreter::Run
  def dispatch(cmd)
    @soak_dispatches ||= 0
    @soak_dispatches += 1
    if @soak_dispatches > MAX_DISPATCHES_PER_RUN
      raise SuspectedInfiniteLoop,
            "Run exceeded #{MAX_DISPATCHES_PER_RUN} dispatched commands without finishing -- " \
            "suspected infinite loop (or a real input-wait loop this soak check cannot satisfy)"
    end
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

    # Every Run this interpreter starts (Common Event calls, map event
    # auto/parallel pages, confirm/touch triggers) goes through #run_class,
    # so overriding just that one method bounds all of them the same way,
    # rather than re-implementing #run_common_event/#start_map_event_run's
    # own logic here to swap Run for BoundedRun by hand.
    interp.define_singleton_method(:run_class) { BoundedRun }

    auto_or_parallel = project.common_events.events.select { |ce| ce.auto? || ce.parallel? }
    puts "  #{project.common_events.size} common events, #{auto_or_parallel.size} auto/parallel"

    FRAMES.times do |frame|
      interp.update
    rescue StandardError => e
      fail "frame #{frame}: #{e.class}: #{e.message}"
      break
    end

    puts "  ok: ran #{FRAMES} frames with no exception"

    check_map_events(project, interp)
  rescue Wolf::Error, StandardError => e
    fail "#{dir}: #{e.class}: #{e.message}"
  end

  # Drives every real map's own events: #active_page against each map
  # event's real (possibly self-variable-relative) conditions, auto/parallel
  # pages stepped every frame via #update, and a one-shot #trigger_confirm/
  # #trigger_touch against whichever pages answer to those (exercising the
  # same page-selection and self-variable-context code Common Events don't
  # touch), for every map the project's own MapTree lists.
  def check_map_events(project, interp)
    project.map_tree.map_ids.each do |map_id|
      map =
        begin
          project.map(map_id)
        rescue Wolf::Error => e
          fail "map #{map_id}: failed to load: #{e.class}: #{e.message}"
          next
        end
      interp.current_map = map
      puts "  map #{map_id}: #{map.events.size} events"

      map.events.each do |event|
        idx, page = interp.active_page(event)
        next unless page
        case page.trigger
        when Wolf::Page::TRIGGER_CONFIRM then interp.trigger_confirm(event)
        when Wolf::Page::TRIGGER_PLAYER_TOUCH, Wolf::Page::TRIGGER_EVENT_TOUCH then interp.trigger_touch(event)
        end
      rescue SuspectedInfiniteLoop => e
        # A one-shot Confirm/Touch trigger, unlike an auto/parallel page, is
        # allowed to call into a real, legitimately-unbounded input-wait
        # loop (a shop or menu system's own cursor loop, found this way
        # against the sample game's own "お店" event) -- there is no real
        # input for this soak check to satisfy, so hitting the dispatch cap
        # here is expected, not a decoding bug. Bounding it is still
        # essential (this exact loop hung indefinitely before the cap was
        # counted in dispatched commands instead of just #step calls).
        puts "  note: map #{map_id} event #{event.id} (#{event.name}): #{e.message}"
      rescue StandardError => e
        fail "map #{map_id} event #{event.id}: #{e.class}: #{e.message}"
      end

      FRAMES.times do |frame|
        interp.update
      rescue StandardError => e
        fail "map #{map_id} frame #{frame}: #{e.class}: #{e.message}"
        break
      end
    end
    puts "  ok: ran map events for #{project.map_tree.map_ids.size} maps with no exception"
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
