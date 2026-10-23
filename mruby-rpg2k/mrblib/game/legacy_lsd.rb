# Read-only migration of version-1 chunk 200 saves.
module Game
  module LegacyLsd
    # Read-only compatibility for saves written before the native field-precision change. No new
    # save emits this chunk. The leading version record distinguishes our
    # old payload from unrelated native/tooling chunk-200 data.
    EXT_TAG_VERSION = 0
    EXT_TAG_WEATHER = 1          # body: type, strength (BER)
    EXT_TAG_ENCOUNTER_TOTAL = 2  # body: total steps (BER)
    EXT_TAG_BOARDED = 3          # body: Vehicle::TYPE_ID id, 0 = not boarded (BER)
    EXT_TAG_FLASH = 4            # body: red, green, blue, frames, total (BER), power (double)
    EXT_TAG_COMMON_PROGRESS = 5  # body: (event id, index) BER pairs
    EXT_TAG_PICTURE_OPACITY = 6  # body: per picture: id (BER), opacity, target opacity (doubles)
    EXT_TAG_PAN = 7              # body: pan x, pan y, target x, target y, step (doubles), locked (BER)
    LSD_EXT_VERSION = 1

    # Every BER integer in a record body, in order.
    def self.ext_ints(body)
      io = StringIO.new(body)
      ints = []
      ints.push(LCF.read_ber(io)) until io.eof?
      ints
    end

    # A double, as 8 little-endian bytes (pack 'E'), and its inverse.
    # (A picture's own name is carried as a length-prefixed byte run.)
    def self.ext_double_at(io)
      raw = io.read(8)
      raise 'truncated extension double' if raw.nil? || raw.bytesize != 8
      raw.unpack('E')[0]
    end

    # [[tag, body], ...] parsed from a chunk-200 payload string.
    def self.ext_records(payload)
      io = StringIO.new(payload)
      records = []
      until io.eof?
        tag = LCF.read_ber(io)
        len = LCF.read_ber(io)
        body = len > 0 ? io.read(len) : ''
        raise 'truncated extension record' if body.nil? || body.bytesize != len
        records.push([tag, body])
      end
      records
    end

    def self.marked?(save)
      payload = save[:lsd_ext]
      return false unless payload && payload[0] == EXT_TAG_VERSION && payload[1] == 1
      raise "unsupported legacy LSD extension version #{payload[2]}" unless payload[2] == LSD_EXT_VERSION
      true
    end

    # Legacy values override native approximations only for a marked old save.
    def self.apply(state, save)
      return state unless marked?(save)
      payload = save[:lsd_ext]
      ext_records(payload.pack('C*')).each do |tag, body|
        case tag
        when EXT_TAG_WEATHER
          ints = ext_ints(body)
          state.weather.set(ints[0] || 0, ints[1] || 0)
        when EXT_TAG_ENCOUNTER_TOTAL
          state.encounter_total = ext_ints(body)[0] || 0
        when EXT_TAG_BOARDED
          id = ext_ints(body)[0] || 0
          state.boarded = nil
          Vehicle::TYPE_ID.each { |type, type_id| state.boarded = type if type_id == id }
        when EXT_TAG_FLASH
          io = StringIO.new(body)
          ints = [LCF.read_ber(io), LCF.read_ber(io), LCF.read_ber(io),
                  LCF.read_ber(io), LCF.read_ber(io)]
          power = ext_double_at(io)
          state.player_flash = { red: ints[0], green: ints[1], blue: ints[2],
                                 power: power, frames: ints[3], total: ints[4] }
        when EXT_TAG_COMMON_PROGRESS
          pairs = ext_ints(body)
          progress = {}
          i = 0
          while i + 1 < pairs.size
            progress[pairs[i]] = pairs[i + 1]
            i += 2
          end
          state.common_event_progress = progress
        when EXT_TAG_PICTURE_OPACITY
          io = StringIO.new(body)
          until io.eof?
            id = LCF.read_ber(io)
            name_len = LCF.read_ber(io)
            name = name_len > 0 ? io.read(name_len) : ''
            opacity = ext_double_at(io)
            has_target = LCF.read_ber(io) != 0
            topacity = has_target ? ext_double_at(io) : nil
            pic = state.pictures[id]
            pic.restore_legacy_lsd(name, opacity, topacity) if pic
          end
        when EXT_TAG_PAN
          # Old records retain pixel doubles rather than native sixteenths.
          io = StringIO.new(body)
          px = ext_double_at(io)
          py = ext_double_at(io)
          tx = ext_double_at(io)
          ty = ext_double_at(io)
          step = ext_double_at(io)
          locked = LCF.read_ber(io) != 0
          state.screen.load_h(pan_x: px, pan_y: py, pan_tx: tx, pan_ty: ty,
                              pan_step: step, pan_locked: locked)
        end
      end
      state
    end

  end

  # Restore old metadata in place so an erased picture stays erased.
  class Picture
    # Name, opacity and target opacity exactly as the save held them. Erased
    # pictures keep their name here (chunk 103 drops it on erase, as RPG_RT does).
    def restore_legacy_lsd(name, opacity, target)
      @name = name
      @opacity = opacity
      @topacity = target
      self
    end
  end
end
