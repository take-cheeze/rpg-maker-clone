class Object
  include RGSS
end

class RPG2k
  WIDTH = 320
  HEIGHT = 240

  def initialize args
    @db = LCF::Database.new File.open "#{GAME_DIR}/RPG_RT.ldb"
    # @map_tree = LCF::MapTree.new "#{GAME_DIR}/RPG_RT.lmt"

    @title = Sprite.new
    @title.bitmap = Bitmap.new "Title/#{@db.system.title}"
  end

  def start
    loop do
      # Input.update
      Graphics.update
    end
  rescue RGSS::Timeout
  end
end
