#!/usr/bin/env ruby
# frozen_string_literal: true

# HEAPWALK report: reads the snapshots the wio_renode_game_heapwalk firmware writes (app/wio/src/wio_heapwalk.cxx,
# scripts/wio/renode_game.bash --heapwalk DIR) and breaks each heap down by owner.
#
#   scripts/wio/heapwalk_report.rb ELF DIR [--snap NAME_REGEX] [--top N] [--nm NM]
#
# A malloc block belongs to the mruby object whose slot holds its address (a String's buffer, an Array's values, an
# ivar table, a C data's struct), and to that owner too when only another owned block points at it (a hash's entries,
# a bitmap's pixels). The rest is charged to the first allocating function outside the allocator plumbing (malloc,
# mrb_realloc, lv_malloc, operator new, std::), named from the ELF's symbols. GC pages are split by object type and
# class. Sizes are the blocks' usable bytes; newlib-nano adds a 4-byte header to each.
require 'optparse'

top = 25
snap_re = nil
largest = 0
nm = ENV.fetch('ARM_NM', File.expand_path('~/.platformio/packages/toolchain-gccarmnoneeabi/bin/arm-none-eabi-nm'))
OptionParser.new do |o|
  o.on('--snap RE') { |v| snap_re = Regexp.new(v) }
  o.on('--top N', Integer) { |v| top = v }
  o.on('--largest N', Integer, 'also list the N largest blocks with their whole stacks') { |v| largest = v }
  o.on('--nm NM') { |v| nm = v }
end.parse!
elf, dir = ARGV
abort 'usage: heapwalk_report.rb ELF DIR [--snap RE] [--top N]' unless elf && dir && File.directory?(dir)

TT = %w[false true symbol undef free float integer cptr object class module sclass hash cdata exception iclass proc
        array string range env fiber struct istruct break complex rational bigint backtrace set].freeze
TT_FREE = 4
PAGE_HEADER = 20
PAGE_OBJECTS = 256
CHAIN = 12
HEADER = 'a4L11a64'
HEADER_SIZE = 112
RECORD_SIZE = 4 * (3 + CHAIN)

syms = []
IO.popen([nm, '-C', '-S', '--defined-only', elf], &:readlines).each do |line|
  f = line.chomp.split(' ', 4)
  next unless f.size == 4 && f[2] =~ /\A[tTwW]\z/

  syms << [f[0].to_i(16) & ~1, f[1].to_i(16), f[3]]
end
syms.sort_by!(&:first)
SYM_ADDR = syms.map(&:first)
SYMS = syms
def fn_of(addr)
  a = addr & ~1
  i = SYM_ADDR.bsearch_index { |x| x > a }
  i = (i || SYM_ADDR.size) - 1
  return format('0x%x', a) if i.negative?

  s, size, name = SYMS[i]
  size.positive? && a >= s + size + 4 ? format('0x%x', a) : name
end

PLUMBING = /\A(malloc|calloc|realloc|free|operator\ new|operator\ delete|\(anonymous\ namespace\)::note|mrb_default_allocf|
  mrb_basic_alloc_func|mrb_realloc|mrb_realloc_simple|mrb_malloc|mrb_malloc_simple|mrb_calloc|mrb_temp_alloc|lv_malloc|
  lv_malloc_core|lv_malloc_zeroed|lv_realloc|lv_realloc_core|lv_calloc|lv_zalloc|std::|__gnu_cxx::|void\ std::)/x
# Pixel and palette buffers: a Bitmap's own, a deferred bitmap's op list, a decode's output.
PIXELS = /Bitmap::Bitmap|deferred_|bmp_decode|png_|xyz_inflate|promote_to_direct|rom_bitmap/
RUBY_METHOD = /\A\w+_impl\w*\(/
def site_of(chain, memo)
  memo[chain] ||= begin
    names = chain.reject(&:zero?).map { |a| fn_of(a) }
    names.shift while names.size > 1 && names.first =~ PLUMBING
    # The allocating function, and the first compiled Ruby method (an _impl) above it.
    ruby = names.drop(1).find { |n| n =~ RUBY_METHOD }
    [names.first, ruby].compact.map { |n| n.gsub('(anonymous namespace)', 'anon').sub(/\(.*/m, '') }.join(' < ')
  end
end

def category(site)
  case site
  when /\Alv_|< lv_|\Alv\w/ then 'lvgl'
  when /\Amrb_|\Akh_|\Agc_|\Asym|\Aiv_|\Amt_|\Aary_|\Astr_|\Ahash|\Aht_/ then 'mruby core'
  when /\Abc2cpp|\ARPG|\AGame|\AScene|\AWindow|\ASprite|\ALCF|::/ then 'engine'
  else 'other'
  end
end

def kb(n) = format('%.1f', n / 1024.0)

def table(rows, head, top)
  total = rows.sum { |r| r[2] }
  puts head
  rows.sort_by { |r| -r[2] }.first(top).each do |label, n, bytes|
    puts format('  %8s KB %6d  %s', kb(bytes), n, label)
  end
  rest = rows.sort_by { |r| -r[2] }.drop(top)
  puts format('  %8s KB %6d  (%d more)', kb(rest.sum { |r| r[2] }), rest.sum { |r| r[1] }, rest.size) unless rest.empty?
  puts format('  %8s KB total', kb(total))
end

classes = {}
summary = []
memo = {}
Dir[File.join(dir, 'snap-*.out')].sort.each do |out_path|
  out = File.binread(out_path)
  magic, slot, kind, frame, live, inuse, sbrk_top, heap_base, n_blocks, n_class_bytes, = out.unpack(HEADER)
  name = out[48, 64].unpack1('Z*')
  next unless magic == 'HWS1'

  recs = Array.new(n_blocks) do |i|
    w = out.unpack("L#{3 + CHAIN}", offset: HEADER_SIZE + i * RECORD_SIZE)
    { ptr: w[0], req: w[1], usable: w[2], chain: w[3, CHAIN] }
  end
  out.byteslice(HEADER_SIZE + n_blocks * RECORD_SIZE, n_class_bytes).each_line do |l|
    a, cname = l.chomp.split(' ', 2)
    classes[a.to_i(16)] = cname
  end
  next if snap_re && name !~ snap_re

  heap = File.binread(out_path.sub(/\.out\z/, '.heap'))
  word = ->(addr) { heap.unpack1('L', offset: addr - heap_base) }
  by_ptr = recs.to_h { |r| [r[:ptr], r] }

  # GC pages: the most common size of the PAGE_HEADER + 256 * slot form.
  slot_size = [20, 24, 28, 32].max_by { |s| recs.count { |r| r[:req] == PAGE_HEADER + PAGE_OBJECTS * s } }
  pages = recs.select { |r| r[:req] == PAGE_HEADER + PAGE_OBJECTS * slot_size }
  pages.each { |r| r[:owner] = 'gc page' }
  objs = []
  pages.each do |pg|
    PAGE_OBJECTS.times do |j|
      a = pg[:ptr] + PAGE_HEADER + j * slot_size
      tt = word.(a + 4) & 0xff
      next if tt == TT_FREE

      cls = word.(a)
      objs << [a, tt, cls]
    end
  end
  owner_label = lambda do |tt, cls, addr|
    case tt
    when 9, 10 then "#{TT[tt]}:#{classes[addr] || '?'}"
    when 11, 15 then TT[tt]
    else "#{TT[tt]}:#{classes[cls] || '?'}"
    end
  end
  # A word points into a block when it lies inside one (C++ objects hand out interior pointers: make_shared).
  starts = recs.map { |r| r[:ptr] }.sort
  by_start = recs.to_h { |r| [r[:ptr], r] }
  block_at = lambda do |w|
    i = starts.bsearch_index { |x| x > w }
    i = (i || starts.size) - 1
    return nil if i.negative?

    r = by_start[starts[i]]
    w < r[:ptr] + [r[:usable], 4].max ? r : nil
  end
  # mrb_state reaches everything; its own blocks are charged to their sites.
  recs.each { |r| r[:noscan] = true if site_of(r[:chain], memo).start_with?('mrb_open_core') }
  queue = []
  objs.each do |a, tt, cls|
    label = owner_label.(tt, cls, a)
    (2...(slot_size / 4)).each do |k|
      b = block_at.(word.(a + 4 * k))
      next if !b || b[:owner]

      b[:owner] = label
      b[:direct] = TT[tt]
      queue << b unless tt == 18 # a String's bytes hold no pointers
    end
  end
  until queue.empty?
    b = queue.shift
    next if b[:noscan]

    (0...(b[:usable] / 4)).each do |k|
      c = block_at.(word.(b[:ptr] + 4 * k))
      next if !c || c[:owner] || c[:noscan]

      c[:owner] = b[:owner]
      c[:direct] = "#{b[:direct]}>"
      queue << c
    end
  end

  tracked = recs.sum { |r| r[:usable] }
  page_bytes = pages.sum { |r| r[:usable] }
  owned = recs.select { |r| r[:owner] && r[:owner] != 'gc page' }
  unowned = recs.reject { |r| r[:owner] }
  unowned.each { |r| r[:site] = site_of(r[:chain], memo) }
  cats = Hash.new(0)
  unowned.each { |r| cats[category(r[:site])] += r[:usable] }
  # The summary's columns: every tracked block in exactly one.
  cols = Hash.new(0)
  recs.each do |r|
    names = r[:chain].reject(&:zero?).map { |a| fn_of(a) }
    col = if r[:owner] == 'gc page' then 'gcpage'
          elsif names.any? { |n| n =~ PIXELS } then 'pixels'
          elsif r[:owner].nil? then 'unowned'
          else
            case r[:owner][/\A\w+/]
            when 'string' then 'string'
            when 'array' then 'array'
            when 'hash' then 'hash'
            when 'class', 'module', 'sclass', 'iclass' then 'class'
            else 'cdata'
            end
          end
    cols[col] += r[:usable] + 4
  end
  summary << [name, frame, sbrk_top - heap_base, inuse, cols]

  puts "== #{File.basename(out_path, '.out')} #{name} f=#{frame} #{kind == 1 ? '(peak)' : ''}"
  puts format('heap extent %s KB, mallinfo inuse %s KB, tracked %s KB in %d blocks (+%s KB headers), untracked %s KB',
              kb(sbrk_top - heap_base), kb(inuse), kb(tracked), recs.size, kb(4 * recs.size),
              kb(inuse - tracked - 4 * recs.size))
  puts format('GC pages: %d x %d B (slot %d B) = %s KB; %d live slots, %d free',
              pages.size, pages.first ? pages.first[:usable] : 0, slot_size, kb(page_bytes), objs.size,
              pages.size * PAGE_OBJECTS - objs.size)

  by_tt = Hash.new { |h, k| h[k] = [k, 0, 0] }
  objs.each { |_, tt, _| by_tt[TT[tt]][1] += 1; by_tt[TT[tt]][2] += slot_size }
  table(by_tt.values, 'live slots by type (slot bytes):', top)

  cost = Hash.new { |h, k| h[k] = [k, 0, 0] }
  objs.each { |a, tt, cls| e = cost[owner_label.(tt, cls, a)]; e[1] += 1; e[2] += slot_size }
  owned.each { |r| cost[r[:owner]][2] += r[:usable] + 4 }
  table(cost.values, 'by owner object (slots + owned blocks incl. headers; count = objects):', top)

  ob = Hash.new { |h, k| h[k] = [k, 0, 0] }
  owned.each { |r| e = ob["#{r[:direct]} #{r[:owner][/\A\w+/]}"]; e[1] += 1; e[2] += r[:usable] }
  table(ob.values, 'owned blocks by holder type (> = reached through another block):', top)

  os = Hash.new { |h, k| h[k] = [k, 0, 0] }
  owned.each { |r| e = os["#{r[:owner]} | #{site_of(r[:chain], memo)}"]; e[1] += 1; e[2] += r[:usable] }
  table(os.values, 'owned blocks by owner and allocating function:', top)

  us = Hash.new { |h, k| h[k] = [k, 0, 0] }
  unowned.each { |r| e = us[r[:site]]; e[1] += 1; e[2] += r[:usable] }
  table(us.values, 'blocks no object owns, by allocating function:', top)

  hist = Hash.new { |h, k| h[k] = [k, 0, 0] }
  recs.each do |r|
    b = [16, 32, 64, 128, 256, 512, 1024, 4096, 16_384].find { |x| r[:usable] <= x } || 'big'
    e = hist[b.is_a?(Integer) ? format('<=%5d', b) : '>16384'];
    e[1] += 1
    e[2] += r[:usable]
  end
  if largest.positive?
    puts 'largest blocks:'
    recs.max_by(largest) { |r| r[:usable] }.each do |r|
      puts format('  %8s KB  %s', kb(r[:usable]), r[:owner] || '-')
      r[:chain].reject(&:zero?).each { |a| puts "      #{fn_of(a).gsub('(anonymous namespace)', 'anon')[0, 150]}" }
    end
  end
  puts 'block sizes:'
  hist.values.sort_by(&:first).each { |l, n, bytes| puts format('  %s: %6d blocks %8s KB', l, n, kb(bytes)) }
  puts
end

COLS = %w[gcpage pixels string array hash cdata class unowned].freeze
puts '== summary (KB, block bytes incl. the 4-byte header; pixels: bitmap buffers whoever holds them)'
puts format("%-34s %5s %7s %7s#{' %7s' * COLS.size}", 'snapshot', 'frame', 'extent', 'inuse', *COLS)
summary.each do |n, f, ext, inuse, cols|
  puts format("%-34s %5d %7s %7s#{' %7s' * COLS.size}", n[0, 34], f, kb(ext), kb(inuse), *COLS.map { |c| kb(cols[c]) })
end
