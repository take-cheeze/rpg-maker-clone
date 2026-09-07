# WOLF RPG Editor SaveVariable(222)/LoadVariable(221) ("セーブデータへの
# 書き込み"/"セーブデータからの読み込み", help/04ev_file.html) and
# SaveLoad(220)'s own "保存・読込" operation (see interpreter.rb's own
# `#exec_save_load`): 221/222 only ever touch one variable or string at a
# time, keyed by its own raw WOLF value-ref id, inside a small per-save-
# slot key/value blob; 220 stores its own deliberately partial whole-
# reader snapshot (`VarStore#snapshot`'s four flat banks, plus the current
# map/hero position -- *not* self-variables, the database, or anything
# else a real `.sav` file also carries) under a reserved Symbol key
# (`Wolf::Interpreter::SAVE_LOAD_FULL_SAVE_KEY`) in the exact same file,
# alongside whatever 221/222 keys (always raw Integer ids, so they can
# never collide with a Symbol) already live there.
#
# Persisted as a flat `{raw_id => value}` Hash via Marshal, matching the
# same "serialize a plain Ruby value straight to a project-relative file"
# pattern mruby-rpg2k's own Game#save_game/#load_save_state and
# mruby-rpgxp's own RGSSData#save_object/#read_object already use
# elsewhere in this codebase -- not WOLF's own real `.sav` format, since
# nothing else in this reader ever needs to read a real WOLF save file
# back (a real `.sav` also carries a full 可変DB snapshot, XY arrays, and
# more that this deliberately small key/value blob does not attempt).
module Wolf
  module SaveData
    # help/04ev_file.html's own documented Ver3.00+ restriction on a
    # string-named save file ("特殊機能　保存ファイル名を文字列変数で指
    # 定"): none of these may appear, so a save always lands inside the
    # project directory rather than escaping it.
    FORBIDDEN_NAME_TOKENS = ['//', '\\', '..', './', '.\\', '%', ':', '*', '?', '"', '<', '>', '|'].freeze

    def self.safe_name?(name)
      FORBIDDEN_NAME_TOKENS.none? { |tok| name.include?(tok) }
    end

    # `save_number_raw`'s own decoded kind picks the file: a string-typed
    # ref (help/04ev_file.html's own "保存ファイル名を文字列変数で指
    # 定") names the file directly, relative to the project root, exactly
    # as typed; anything else resolves to a plain number and names
    # `Save/SaveDataNN.sav` (the manual's own documented default, e.g.
    # "Save/SaveData01.sav" for save data number 1). Returns nil for an
    # unsafe string name -- callers treat that the same as "no such save".
    def self.path_for(project_dir, save_number_raw, var_store)
      if var_store.string_ref?(save_number_raw)
        name = var_store.string(save_number_raw)
        return nil unless safe_name?(name)

        File.join(project_dir, name)
      else
        File.join(project_dir, "Save", format("SaveData%02d.sav", var_store.number(save_number_raw)))
      end
    end

    def self.read(path)
      return {} unless path && File.exist?(path)

      Marshal.load(File.open(path, "rb") { |f| f.read })
    rescue StandardError
      {}
    end

    def self.write(path, data)
      return unless path

      dir = File.dirname(path)
      Dir.mkdir(dir) unless Dir.exist?(dir)
      File.open(path, "wb") { |f| f.write(Marshal.dump(data)) }
    end
  end
end
