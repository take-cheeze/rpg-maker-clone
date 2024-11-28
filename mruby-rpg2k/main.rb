using RGSS

class RPG2k
  def initialize
    @db = LCF::Database.new "#{GAME_DIR}/RPG_RT.ldb"
    # @map_tree = LCF::MapTree.new "#{GAME_DIR}/RPG_RT.lmt"

    @title = Sprite.new
    @title.bitmap = Bitmap.new db.system.title
  end

  def start
    loop do
      Graphics.update
      Input.update
    end
  end
end
