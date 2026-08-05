# RPG Maker VX / VX Ace database loader.
#
# The VX counterpart of RPGXP::RGSSData: each accessor is simply the
# `Marshal.load` of the matching `Data/<name>.rvdata(2)` file, with the record
# classes declared in rgss2_data.rb. Two things differ from the XP loader:
#
#   * the file extension depends on the edition (`.rvdata` for VX, `.rvdata2`
#     for VX Ace), so the database is built for a detected edition;
#   * the table set differs — VX ships `Areas` (named map rectangles with their
#     own encounters) and no tilesets (it has one game-wide tileset, whose
#     passage flags live in `System#passages`), while VX Ace dropped areas and
#     added per-map `Tilesets`.
#
# The array-typed tables (Actors, Items, ...) are 1-based with a nil at index 0,
# exactly as the editor writes them; MapInfos is a Hash keyed by map id. Maps are
# large and loaded on demand.
#
# Encrypted releases are handled by the XP archive reader (`RPGXP::RGSSAD`),
# which already decodes VX's version-1 `Game.rgss2a` and VX Ace's version-3
# `Game.rgss3a`; a loose file on disk shadows the archive, matching RGSS.
class RPGVX
  class RGSSData
    # The Data/ files both editions ship as an index-addressed array of records.
    # Each becomes a reader of the same (lower-cased, plural) name.
    ARRAY_FILES = {
      actors: "Actors", classes: "Classes", skills: "Skills",
      items: "Items", weapons: "Weapons", armors: "Armors",
      enemies: "Enemies", troops: "Troops", states: "States",
      animations: "Animations", common_events: "CommonEvents"
    }.freeze

    # Tables only one edition has. Missing on the other edition, where the
    # reader answers nil.
    EDITION_FILES = {
      vx: { areas: "Areas" },
      vxace: { tilesets: "Tilesets" }
    }.freeze

    # Every reader this class defines, so a caller can enumerate the database.
    ALL_FILES = ARRAY_FILES.keys +
                EDITION_FILES.values.map { |files| files.keys }.flatten

    def initialize(game_dir, edition = nil)
      @game_dir = game_dir
      @edition = edition || RPGVX.detect(game_dir)
      raise "#{game_dir} is not an RPG Maker VX / VX Ace project" unless @edition
      @ext = RPGVX.data_ext(@edition)
      @archive = open_archive
      @system = load_data("System")
      @map_infos = load_data("MapInfos")
      @cache = {}
      ARRAY_FILES.each { |name, file| @cache[name] = load_data(file) }
      EDITION_FILES[@edition].each { |name, file| @cache[name] = load_data(file) }
    end

    attr_reader :system, :map_infos, :game_dir, :edition, :ext

    ALL_FILES.each do |name|
      define_method(name) { @cache[name] }
    end

    # Load one map (Data/MapNNN.rvdata(2)) by id. Maps are big, so they are not
    # cached with the rest of the database — the caller loads the one it needs.
    # Ids are zero-padded to three digits (Map001) without sprintf/format, which
    # the XP loader avoids for the same reason (this mruby build's gem set is
    # trimmed).
    def load_map(id)
      num = id.to_s
      num = "0#{num}" while num.size < 3
      load_data("Map#{num}")
    end

    # Absolute path of a Data/ entry.
    def data_path(base)
      "#{@game_dir}/Data/#{base}#{@ext}"
    end

    # Whether this project's data lives in an encrypted archive
    # (Game.rgss2a / Game.rgss3a).
    def archived?
      !@archive.nil?
    end

    # The opened archive, or nil for an unpacked project. A packed release keeps
    # its Graphics/ and Audio/ trees in here too, so the boot shell hands this to
    # RGSS.asset_archive and the native asset loaders read through it.
    attr_reader :archive

    def vxace?
      @edition == :vxace
    end

    # A one-line census of what loaded, for the boot log.
    def summary
      counts = ALL_FILES.map do |name|
        table = @cache[name]
        next nil unless table
        "#{name}=#{table.compact.size}"
      end
      counts = counts.compact
      counts.unshift "maps=#{(@map_infos || {}).size}"
      counts.join(" ")
    end

    # Read + Marshal-parse an arbitrary project-relative file, exactly like
    # RGSS's Kernel#load_data ("Data/System.rvdata2", "Save1.rvdata2", ...). A
    # loose file on disk shadows the archive, matching RGSS; when there is none
    # the entry is pulled from the encrypted archive. The RGSS script host uses
    # this to feed Kernel#load_data.
    def read_object(relative_path)
      full = "#{@game_dir}/#{relative_path}"
      return File.open(full, "rb") { |f| Marshal.load(f.read) } if File.exist?(full)
      if @archive
        bytes = @archive.read(relative_path)
        return Marshal.load(bytes) if bytes
      end
      raise "cannot load #{relative_path}: no loose file and no archive entry"
    end

    # Marshal-dump `obj` to a project-relative file (RGSS's Kernel#save_data).
    # Always writes a loose file under the game directory — RGSS never writes
    # back into the encrypted archive — so in-game saving works on a packed
    # project too.
    def save_object(obj, relative_path)
      File.open("#{@game_dir}/#{relative_path}", "wb") { |f| f.write(Marshal.dump(obj)) }
    end

    # Whether the project ships a script bundle (loose Data/Scripts.rvdata(2) or
    # the archive entry). Cheap presence check — does not decode the scripts.
    def scripts?
      File.exist?(data_path("Scripts")) ||
        (!@archive.nil? && @archive.include?("Data/Scripts#{@ext}"))
    end

    # The bundled RGSS scripts as an ordered array of [name, source]. The bundle
    # has the same shape as XP's: a Marshal array of [id, name, zlib-deflated
    # source] sections, evaluated top to bottom (the final "Main" section drives
    # the game). Empty when the project ships no scripts.
    def scripts
      return [] unless scripts?
      read_object("Data/Scripts#{@ext}").map do |section|
        _id, name, deflated = section
        [name.to_s, RGSS.zlib_inflate(deflated.to_s)]
      end
    end

    private

    # Open the game's encrypted archive if it exists, so a packed project with no
    # loose Data/ folder still loads. Only this edition's archive counts:
    # `RGSSAD.find` would also answer an XP `.rgssad`, which cannot hold
    # `.rvdata` entries. Best effort — an unreadable archive is logged and
    # treated as absent.
    def open_archive
      path = "#{@game_dir}/#{RPGVX.info(@edition)[:archive]}"
      return nil unless File.exist?(path)
      RPGXP::RGSSAD.open(path)
    rescue StandardError => e
      $stderr.puts "[RGSS2] failed to open archive #{path}: #{e.message}"
      nil
    end

    # Load and Marshal-parse a Data/ entry by base name (System, MapInfos,
    # Map001, ...). Delegates to the public read_object, which reads a loose file
    # before the archive, matching RGSS.
    def load_data(base)
      read_object("Data/#{base}#{@ext}")
    end
  end
end
